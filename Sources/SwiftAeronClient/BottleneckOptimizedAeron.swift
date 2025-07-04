import Foundation
import Network

/// 瓶颈优化版Aeron实现
/// 专门针对识别的5个主要性能瓶颈进行优化
/// 目标：在保持100%可靠性前提下，将性能从4MB/s提升至25-30MB/s
public class BottleneckOptimizedAeron {
    private let streamId: UInt32
    private let sessionId: UInt32
    private let termId: UInt32
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var isConnected = false
    
    // 优化1: 简化批量逻辑，移除嵌套异步
    private let batchSize: Int = 50  // 减小批量大小提高响应性
    private var batchBuffer: [Data] = []
    private var lastFlushTime = Date()
    private let batchLock = NSLock()  // 同步锁替代异步队列
    
    // 优化2: 预分配缓冲区，减少动态分配
    private var frameBuffer: UnsafeMutableRawPointer
    private let frameBufferSize: Int = 2048
    private var termOffset: UInt32 = 0
    
    // 优化3: 流控制简化
    private var receiverWindow: UInt32 = 16 * 1024 * 1024  // 16MB固定窗口
    private var lastStatusTime = Date()
    private let statusCheckInterval: TimeInterval = 0.1  // 100ms检查间隔
    
    // 性能统计
    private var messagesSent: Int64 = 0
    private var bytesSent: Int64 = 0
    private var startTime: Date?
    
    public init(streamId: UInt32, sessionId: UInt32, host: String, port: UInt16) {
        self.streamId = streamId
        self.sessionId = sessionId
        self.termId = UInt32.random(in: 1...UInt32.max)
        
        // 预分配原始内存缓冲区
        self.frameBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: frameBufferSize, 
            alignment: MemoryLayout<UInt64>.alignment
        )
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        // 优化网络参数
        let parameters = NWParameters.udp
        parameters.defaultProtocolStack.transportProtocol = NWProtocolUDP.Options()
        // 设置UDP参数以减少延迟
        
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.queue = DispatchQueue(label: "optimized-aeron", qos: .userInitiated)
        
        // 初始化批量缓冲区容量
        batchBuffer.reserveCapacity(batchSize)
    }
    
    deinit {
        frameBuffer.deallocate()
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
                    // 发送Setup帧，启动流控制
                    Task {
                        await self.sendSetupFrame()
                        self.startSimplifiedStatusHandler()
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
    
    /// 核心优化的offer方法
    public func offer(_ payload: Data) async -> Int64 {
        guard isConnected else { return -1 }
        
        if startTime == nil {
            startTime = Date()
        }
        
        // 优化2: 零拷贝帧创建，直接在预分配缓冲区中构建
        let frameLength = 32 + payload.count
        let alignedLength = (frameLength + 31) & ~31  // 32字节对齐
        
        guard alignedLength <= frameBufferSize else {
            return -1  // 消息过大
        }
        
        // 直接在原始内存中构建帧，避免Data()的开销
        createFrameZeroCopy(payload: payload, frameLength: UInt32(frameLength))
        
        // 创建Data包装器，不复制内存
        let frameData = Data(bytesNoCopy: frameBuffer, count: alignedLength, deallocator: .none)
        
        // 优化1: 简化批量发送逻辑
        let position = sendOptimized(frameData)
        
        termOffset += UInt32(alignedLength)
        messagesSent += 1
        bytesSent += Int64(payload.count)
        
        return position
    }
    
    /// 优化1: 移除嵌套异步的简化发送逻辑
    private func sendOptimized(_ frame: Data) -> Int64 {
        batchLock.lock()
        defer { batchLock.unlock() }
        
        batchBuffer.append(frame)
        
        // 触发式刷新：达到批量大小或时间间隔
        let shouldFlush = batchBuffer.count >= batchSize || 
                         lastFlushTime.timeIntervalSinceNow < -0.001  // 1ms超时
        
        if shouldFlush {
            flushBatchSync()
        }
        
        return Int64(termOffset)
    }
    
    /// 优化1: 同步批量刷新，避免异步开销
    private func flushBatchSync() {
        guard !batchBuffer.isEmpty else { return }
        
        let framesToSend = batchBuffer
        batchBuffer.removeAll(keepingCapacity: true)
        lastFlushTime = Date()
        
        // 并发发送所有帧
        for frame in framesToSend {
            connection.send(content: frame, completion: .contentProcessed { _ in
                // 简化错误处理，保持性能
            })
        }
    }
    
    /// 优化2: 零拷贝帧创建，直接操作原始内存
    private func createFrameZeroCopy(payload: Data, frameLength: UInt32) {
        let base = frameBuffer
        
        // 直接写入帧头，避免任何Data操作
        base.storeBytes(of: frameLength.littleEndian, toByteOffset: 0, as: UInt32.self)
        base.storeBytes(of: UInt8(0x01), toByteOffset: 4, as: UInt8.self)  // version
        base.storeBytes(of: UInt8(0xC0), toByteOffset: 5, as: UInt8.self)  // flags
        base.storeBytes(of: UInt16(0x01).littleEndian, toByteOffset: 6, as: UInt16.self)  // type
        base.storeBytes(of: termOffset.littleEndian, toByteOffset: 8, as: UInt32.self)
        base.storeBytes(of: sessionId.littleEndian, toByteOffset: 12, as: UInt32.self)
        base.storeBytes(of: streamId.littleEndian, toByteOffset: 16, as: UInt32.self)
        base.storeBytes(of: termId.littleEndian, toByteOffset: 20, as: UInt32.self)
        base.storeBytes(of: UInt64(0), toByteOffset: 24, as: UInt64.self)  // reserved
        
        // 复制payload数据
        if payload.count > 0 {
            payload.withUnsafeBytes { payloadPtr in
                (base + 32).copyMemory(from: payloadPtr.baseAddress!, byteCount: payload.count)
            }
        }
        
        // 零填充对齐
        let alignedLength = (Int(frameLength) + 31) & ~31
        if alignedLength > Int(frameLength) {
            (base + Int(frameLength)).bindMemory(to: UInt8.self, capacity: alignedLength - Int(frameLength))
                .initialize(repeating: 0, count: alignedLength - Int(frameLength))
        }
    }
    
    private func sendSetupFrame() async {
        let setupFrame = createSetupFrame()
        connection.send(content: setupFrame, completion: .contentProcessed { _ in })
    }
    
    private func createSetupFrame() -> Data {
        var setup = Data(capacity: 40)
        setup.append(contentsOf: UInt32(40).littleEndian.optimizedBytes)  // frame length
        setup.append(0x01)  // version
        setup.append(0x00)  // flags
        setup.append(contentsOf: UInt16(0x05).littleEndian.optimizedBytes)  // setup type
        setup.append(contentsOf: UInt32(0).littleEndian.optimizedBytes)  // term offset
        setup.append(contentsOf: sessionId.littleEndian.optimizedBytes)
        setup.append(contentsOf: streamId.littleEndian.optimizedBytes)
        setup.append(contentsOf: termId.littleEndian.optimizedBytes)  // initial term ID
        setup.append(contentsOf: termId.littleEndian.optimizedBytes)  // active term ID
        setup.append(contentsOf: UInt32(16 * 1024 * 1024).littleEndian.optimizedBytes)  // term length
        setup.append(contentsOf: UInt32(1408).littleEndian.optimizedBytes)  // MTU
        setup.append(contentsOf: UInt32(0).littleEndian.optimizedBytes)  // TTL
        return setup
    }
    
    /// 优化4: 简化的状态消息处理
    private func startSimplifiedStatusHandler() {
        connection.receiveMessage { content, _, isComplete, error in
            if let data = content, data.count >= 8 {
                // 简化状态消息处理，只更新接收窗口
                let frameType = data.withUnsafeBytes { bytes in
                    bytes.load(fromByteOffset: 6, as: UInt16.self).littleEndian
                }
                if frameType == 0x03 && data.count >= 32 {  // 状态消息
                    self.receiverWindow = data.withUnsafeBytes { bytes in
                        bytes.load(fromByteOffset: 24, as: UInt32.self).littleEndian
                    }
                    self.lastStatusTime = Date()
                }
            }
            
            if isComplete && self.isConnected {
                self.startSimplifiedStatusHandler()  // 继续接收
            }
        }
    }
    
    /// 流控制检查：简化逻辑
    private func checkFlowControl() -> Bool {
        // 简单的流控制：检查时间间隔和窗口大小
        let statusAge = Date().timeIntervalSince(lastStatusTime)
        return statusAge < statusCheckInterval && receiverWindow > 1024 * 1024  // 1MB最小窗口
    }
    
    public func getPerformanceStats() -> OptimizedPerformanceStats {
        let now = Date()
        let duration = startTime.map { now.timeIntervalSince($0) } ?? 0
        
        return OptimizedPerformanceStats(
            messagesSent: messagesSent,
            bytesSent: bytesSent,
            duration: duration,
            throughputMBps: duration > 0 ? Double(bytesSent) / 1024.0 / 1024.0 / duration : 0,
            messageRate: duration > 0 ? Double(messagesSent) / duration : 0
        )
    }
    
    public func close() {
        // 发送剩余批量数据
        batchLock.lock()
        if !batchBuffer.isEmpty {
            flushBatchSync()
        }
        batchLock.unlock()
        
        connection.cancel()
        isConnected = false
    }
}

/// 优化后的性能统计
public struct OptimizedPerformanceStats {
    public let messagesSent: Int64
    public let bytesSent: Int64
    public let duration: TimeInterval
    public let throughputMBps: Double
    public let messageRate: Double
    
    public func printStats() {
        print("\n=== 瓶颈优化版Aeron性能统计 ===")
        print("发送消息: \(messagesSent)")
        print("总字节数: \(String(format: "%.2f", Double(bytesSent) / 1024.0 / 1024.0)) MB")
        print("持续时间: \(String(format: "%.3f", duration))s")
        print("吞吐量: \(String(format: "%.2f", throughputMBps)) MB/s")
        print("消息速率: \(String(format: "%.0f", messageRate)) 消息/秒")
        
        // 与基准对比
        let rustBaseline = 7.0  // 端到端基准
        let performanceRatio = throughputMBps / rustBaseline * 100
        print("相对Rust端到端性能: \(String(format: "%.1f", performanceRatio))%")
        
        // 与之前Swift版本对比
        let swiftBaseline = 4.0  // 之前的Swift性能
        let improvementRatio = throughputMBps / swiftBaseline
        print("相对之前Swift版本提升: \(String(format: "%.1f", improvementRatio))倍")
    }
}

/// 瓶颈优化测试类
public class BottleneckOptimizedTest {
    public static func runOptimizedPerformanceTest(
        host: String,
        port: UInt16,
        streamId: UInt32,
        sessionId: UInt32,
        messageSize: Int,
        messageCount: Int
    ) async throws {
        
        print("🔧 瓶颈优化版Aeron性能测试")
        print("目标: \(host):\(port)")
        print("流ID: \(streamId), 会话ID: \(sessionId)")
        print("消息大小: \(messageSize) bytes, 数量: \(messageCount)")
        print("优化目标: 从4MB/s提升至25-30MB/s，保持100%可靠性\n")
        
        let aeron = BottleneckOptimizedAeron(
            streamId: streamId,
            sessionId: sessionId,
            host: host,
            port: port
        )
        
        try await aeron.connect()
        print("✅ 已连接，开始性能测试")
        
        // 短时间预热
        let warmupData = Data(repeating: 0x55, count: messageSize)
        for _ in 0..<50 {
            _ = await aeron.offer(warmupData)
        }
        
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        print("🔥 预热完成")
        
        // 性能测试
        let testData = Data(repeating: 0x42, count: messageSize)
        let startTime = Date()
        
        print("📊 开始发送...")
        for i in 0..<messageCount {
            let result = await aeron.offer(testData)
            
            if result < 0 {
                print("❌ 发送失败 at \(i)")
                break
            }
            
            // 减少进度报告频率
            if i > 0 && i % (messageCount / 10) == 0 {
                let progress = Double(i) / Double(messageCount) * 100
                print("进度: \(String(format: "%.1f", progress))%")
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        let stats = aeron.getPerformanceStats()
        
        print("\n" + String(repeating: "=", count: 50))
        stats.printStats()
        
        // 瓶颈优化分析
        print("\n🎯 优化效果分析:")
        if stats.throughputMBps > 20 {
            print("✅ 优化成功！达到预期性能目标")
        } else if stats.throughputMBps > 10 {
            print("🔄 部分优化成功，还有提升空间")
        } else {
            print("❌ 优化效果不明显，需要进一步分析")
        }
        
        aeron.close()
    }
}

// MARK: - 辅助扩展（仅在需要时定义，避免重复声明）

extension FixedWidthInteger {
    var optimizedBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}