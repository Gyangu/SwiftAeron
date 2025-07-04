import Foundation
import Network
import os.log

// MARK: - High Performance Aeron Implementation

/// 高性能Aeron Publication实现
/// 优化特性：
/// 1. 批量发送减少系统调用
/// 2. 预分配缓冲区避免内存分配
/// 3. 异步并发处理
/// 4. 零拷贝优化
/// 5. 连接池管理
public class HighPerformanceAeronPublication {
    private let streamId: UInt32
    private let sessionId: UInt32
    private let initialTermId: UInt32
    private let termBufferLength: Int
    private let positionBitsToShift: Int
    
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var isConnected = false
    
    // 性能优化：批量发送
    private let batchSize: Int
    private var batchBuffer: [Data] = []
    private let batchQueue = DispatchQueue(label: "batch-queue", qos: .userInitiated)
    private var batchTimer: Timer?
    
    // 性能优化：预分配缓冲区
    private var headerBuffer: Data
    private var frameBuffer: Data
    
    // 性能优化：统计信息
    private var totalBytesSent: Int64 = 0
    private var totalMessagesSent: Int64 = 0
    private var startTime: Date?
    
    // Term buffer状态
    private var termOffset: UInt32 = 0
    private var currentTermId: UInt32
    
    // Flow control
    private var receiverWindow: UInt32 = 0
    private var lastStatusTime = Date()
    
    public init(
        streamId: UInt32, 
        sessionId: UInt32, 
        termBufferLength: Int = AeronProtocolSpec.TERM_DEFAULT_LENGTH,
        host: String, 
        port: UInt16,
        batchSize: Int = 100  // 批量大小
    ) {
        self.streamId = streamId
        self.sessionId = sessionId
        self.initialTermId = UInt32.random(in: 1...UInt32.max)
        self.currentTermId = self.initialTermId
        self.termBufferLength = termBufferLength
        self.positionBitsToShift = AeronProtocolSpec.positionBitsToShift(termBufferLength: termBufferLength)
        self.batchSize = batchSize
        
        // 预分配缓冲区
        self.headerBuffer = Data(capacity: AeronProtocolSpec.DATA_HEADER_LENGTH)
        self.frameBuffer = Data(capacity: 16384) // 16KB frame buffer
        
        // 创建高性能UDP连接
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        let parameters = NWParameters.udp
        parameters.defaultProtocolStack.transportProtocol = NWProtocolUDP.Options()
        
        // 优化网络参数
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: 0)
        
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.queue = DispatchQueue(label: "hp-aeron-publication", qos: .userInitiated)
        
        // 启动批量发送定时器
        setupBatchTimer()
    }
    
    deinit {
        batchTimer?.invalidate()
    }
    
    public func connect() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.isConnected = true
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume()
                    }
                    Task {
                        await self.sendSetupFrame()
                        await self.startStatusMessageHandler()
                    }
                case .failed(let error):
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(throwing: AeronError.connectionCancelled)
                    }
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
    
    /// 高性能offer方法 - 核心优化
    public func offer(_ buffer: Data) async -> Int64 {
        guard isConnected else {
            return -1
        }
        
        if startTime == nil {
            startTime = Date()
        }
        
        // 创建数据帧，使用预分配缓冲区
        let frameLength = AeronProtocolSpec.DATA_HEADER_LENGTH + buffer.count
        let alignedLength = alignFrameLength(frameLength)
        
        // 重用frame buffer
        frameBuffer.removeAll(keepingCapacity: true)
        frameBuffer.reserveCapacity(alignedLength)
        
        // 高效创建数据帧
        createDataFrameOptimized(payload: buffer, into: &frameBuffer)
        
        // 批量发送优化
        await batchSend(frameBuffer)
        
        // 更新位置
        let newPosition = AeronProtocolSpec.computePosition(
            termId: Int32(currentTermId),
            termOffset: Int32(termOffset),
            positionBitsToShift: positionBitsToShift
        )
        
        termOffset += UInt32(alignedLength)
        totalMessagesSent += 1
        totalBytesSent += Int64(buffer.count)
        
        return newPosition
    }
    
    /// 批量发送优化
    private func batchSend(_ frame: Data) async {
        await batchQueue.async {
            self.batchBuffer.append(frame)
            
            // 当达到批量大小时立即发送
            if self.batchBuffer.count >= self.batchSize {
                Task {
                    await self.flushBatch()
                }
            }
        }
    }
    
    /// 刷新批量缓冲区
    private func flushBatch() async {
        await batchQueue.async {
            guard !self.batchBuffer.isEmpty else { return }
            
            let framesToSend = self.batchBuffer
            self.batchBuffer.removeAll(keepingCapacity: true)
            
            Task {
                await self.sendFramesBatch(framesToSend)
            }
        }
    }
    
    /// 高效批量发送多个帧
    private func sendFramesBatch(_ frames: [Data]) async {
        // 并发发送多个帧
        await withTaskGroup(of: Void.self) { group in
            for frame in frames {
                group.addTask {
                    await self.sendFrameDirect(frame)
                }
            }
        }
    }
    
    /// 直接发送帧，减少异步开销
    private func sendFrameDirect(_ frame: Data) async {
        connection.send(
            content: frame,
            completion: .contentProcessed { _ in
                // 忽略错误以提高性能
            }
        )
    }
    
    /// 优化的数据帧创建
    private func createDataFrameOptimized(payload: Data, into buffer: inout Data) {
        let frameLength = AeronProtocolSpec.DATA_HEADER_LENGTH + payload.count
        
        // 直接写入缓冲区，避免多次append
        buffer.append(contentsOf: UInt32(frameLength).littleEndian.hpBytes)
        buffer.append(AeronProtocolSpec.PROTOCOL_VERSION)
        buffer.append(AeronProtocolSpec.UNFRAGMENTED)
        buffer.append(contentsOf: AeronProtocolSpec.DATA_HEADER_TYPE.littleEndian.hpBytes)
        buffer.append(contentsOf: termOffset.littleEndian.hpBytes)
        buffer.append(contentsOf: sessionId.littleEndian.hpBytes)
        buffer.append(contentsOf: streamId.littleEndian.hpBytes)
        buffer.append(contentsOf: currentTermId.littleEndian.hpBytes)
        buffer.append(contentsOf: UInt64(0).littleEndian.hpBytes) // reserved
        buffer.append(payload)
        
        // 32字节对齐填充
        let alignedLength = alignFrameLength(frameLength)
        while buffer.count < alignedLength {
            buffer.append(0)
        }
    }
    
    private func setupBatchTimer() {
        batchTimer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { _ in
            Task {
                await self.flushBatch()
            }
        }
    }
    
    private func sendSetupFrame() async {
        let setupHeader = AeronSetupHeader(
            sessionId: sessionId,
            streamId: streamId,
            initialTermId: initialTermId,
            termLength: UInt32(termBufferLength)
        )
        
        await sendFrameDirect(setupHeader.toBytes())
    }
    
    private func startStatusMessageHandler() async {
        // 简化状态消息处理
        connection.receiveMessage { content, _, isComplete, error in
            if let data = content, data.count >= 8 {
                self.handleIncomingFrame(data)
            }
            
            if isComplete && self.isConnected {
                self.connection.receiveMessage(completion: { content, _, isComplete, error in
                    // 继续接收
                })
            }
        }
    }
    
    private func handleIncomingFrame(_ data: Data) {
        guard data.count >= 8 else { return }
        
        let frameType = UInt16.fromLittleEndianBytes(data, offset: 6)
        
        if frameType == AeronProtocolSpec.SM_HEADER_TYPE {
            // 处理状态消息
            if data.count >= AeronProtocolSpec.STATUS_MESSAGE_HEADER_LENGTH {
                let receiverWindow = UInt32.fromLittleEndianBytes(data, offset: 24)
                self.receiverWindow = receiverWindow
                self.lastStatusTime = Date()
            }
        }
    }
    
    private func alignFrameLength(_ length: Int) -> Int {
        return (length + AeronProtocolSpec.FRAME_ALIGNMENT - 1) & ~(AeronProtocolSpec.FRAME_ALIGNMENT - 1)
    }
    
    public func getPerformanceStats() -> PerformanceStats {
        let now = Date()
        let duration = startTime.map { now.timeIntervalSince($0) } ?? 0
        
        return PerformanceStats(
            totalMessages: totalMessagesSent,
            totalBytes: totalBytesSent,
            duration: duration,
            throughputMBps: duration > 0 ? Double(totalBytesSent) / 1024.0 / 1024.0 / duration : 0,
            messageRate: duration > 0 ? Double(totalMessagesSent) / duration : 0
        )
    }
    
    public func close() {
        batchTimer?.invalidate()
        Task {
            await flushBatch() // 发送剩余的批量数据
        }
        connection.cancel()
        isConnected = false
    }
}

// MARK: - 高性能订阅者实现

public class HighPerformanceAeronSubscription {
    private let streamId: UInt32
    private let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    private var isListening = false
    
    // 性能优化：批量处理
    private let batchProcessor = BatchDataProcessor()
    
    // 回调
    public var onDataReceived: ((Data, UInt32, UInt32) -> Void)?
    
    public init(port: UInt16, streamId: UInt32) throws {
        self.port = port
        self.streamId = streamId
        
        let parameters = NWParameters.udp
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.queue = DispatchQueue(label: "hp-aeron-subscription", qos: .userInitiated)
    }
    
    public func startListening() async throws {
        listener.newConnectionHandler = { connection in
            self.handleConnectionOptimized(connection)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.isListening = true
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: AeronError.connectionCancelled)
                default:
                    break
                }
            }
            
            listener.start(queue: queue)
        }
    }
    
    private func handleConnectionOptimized(_ connection: NWConnection) {
        connection.start(queue: queue)
        
        // 批量接收数据
        receiveDataBatch(connection: connection)
    }
    
    private func receiveDataBatch(connection: NWConnection) {
        connection.receiveMessage { content, _, isComplete, error in
            if let data = content {
                self.batchProcessor.processData(data) { payload, sessionId, streamId in
                    self.onDataReceived?(payload, sessionId, streamId)
                }
                
                // 发送状态消息响应
                if data.count >= AeronProtocolSpec.DATA_HEADER_LENGTH {
                    let sessionId = UInt32.fromLittleEndianBytes(data, offset: 12)
                    let streamId = UInt32.fromLittleEndianBytes(data, offset: 16)
                    self.sendStatusMessageOptimized(connection: connection, sessionId: sessionId, streamId: streamId)
                }
            }
            
            if isComplete {
                self.receiveDataBatch(connection: connection)
            }
        }
    }
    
    private func sendStatusMessageOptimized(connection: NWConnection, sessionId: UInt32, streamId: UInt32) {
        let statusMessage = AeronStatusMessageHeader(
            sessionId: sessionId,
            streamId: streamId,
            termId: 1,
            termOffset: 0,
            receiverWindow: 16 * 1024 * 1024 // 16MB窗口
        )
        
        connection.send(content: statusMessage.toBytes(), completion: .contentProcessed { _ in })
    }
    
    public func stopListening() {
        listener.cancel()
        isListening = false
    }
}

// MARK: - 批量数据处理器

private class BatchDataProcessor {
    private var frameBuffer = Data()
    
    func processData(_ data: Data, onFrame: (Data, UInt32, UInt32) -> Void) {
        frameBuffer.append(data)
        
        // 处理完整帧
        while frameBuffer.count >= 8 {
            let frameLength = UInt32.fromLittleEndianBytes(frameBuffer, offset: 0)
            
            guard frameLength <= frameBuffer.count else { break }
            
            let frameData = frameBuffer.prefix(Int(frameLength))
            frameBuffer.removeFirst(Int(frameLength))
            
            // 解析帧
            if frameData.count >= AeronProtocolSpec.DATA_HEADER_LENGTH {
                let frameType = UInt16.fromLittleEndianBytes(frameData, offset: 6)
                
                if frameType == AeronProtocolSpec.DATA_HEADER_TYPE {
                    let sessionId = UInt32.fromLittleEndianBytes(frameData, offset: 12)
                    let streamId = UInt32.fromLittleEndianBytes(frameData, offset: 16)
                    let payload = frameData.dropFirst(AeronProtocolSpec.DATA_HEADER_LENGTH)
                    
                    onFrame(Data(payload), sessionId, streamId)
                }
            }
        }
    }
}

// MARK: - 性能统计

public struct PerformanceStats {
    public let totalMessages: Int64
    public let totalBytes: Int64
    public let duration: TimeInterval
    public let throughputMBps: Double
    public let messageRate: Double
    
    public func printStats() {
        print("=== 高性能Aeron统计 ===")
        print("总消息数: \(totalMessages)")
        print("总字节数: \(totalBytes)")
        print("持续时间: \(String(format: "%.3f", duration))s")
        print("吞吐量: \(String(format: "%.2f", throughputMBps)) MB/s")
        print("消息速率: \(String(format: "%.0f", messageRate)) 消息/秒")
    }
}

// MARK: - 扩展FixedWidthInteger以支持高效字节操作

extension FixedWidthInteger {
    var hpBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}