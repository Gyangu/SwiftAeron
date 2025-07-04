import Foundation
import Network

// MARK: - Aeron核心设计规范实现

/// Aeron日志缓冲区描述符 - 按照真正的Aeron规范
public class AeronLogBufferDescriptor {
    // Aeron规范的缓冲区大小
    public static let MIN_TERM_LENGTH = 64 * 1024         // 64KB
    public static let MAX_TERM_LENGTH = 1024 * 1024 * 1024 // 1GB
    public static let MIN_PAGE_SIZE = 4 * 1024            // 4KB
    public static let MAX_PAGE_SIZE = 1024 * 1024 * 1024  // 1GB
    
    // 术语缓冲区数量 - Aeron使用3个术语缓冲区轮换
    public static let PARTITION_COUNT = 3
    
    // 帧对齐 - Aeron要求32字节对齐
    public static let FRAME_ALIGNMENT = 32
    
    // 日志元数据长度
    public static let LOG_META_DATA_LENGTH = 4 * 1024 // 4KB
    
    // 术语元数据偏移量
    public static let TERM_TAIL_COUNTERS_OFFSET = 0
    public static let ACTIVE_TERM_COUNT_OFFSET = TERM_TAIL_COUNTERS_OFFSET + (PARTITION_COUNT * 8)
    public static let END_OF_STREAM_POSITION_OFFSET = ACTIVE_TERM_COUNT_OFFSET + 8
    public static let IS_CONNECTED_OFFSET = END_OF_STREAM_POSITION_OFFSET + 8
    
    public let termLength: Int
    public let pageSize: Int
    public let termBuffers: [UnsafeMutableRawPointer]
    public let metaDataBuffer: UnsafeMutableRawPointer
    
    public init(termLength: Int, pageSize: Int) {
        self.termLength = termLength
        self.pageSize = pageSize
        
        // 分配3个术语缓冲区
        self.termBuffers = (0..<Self.PARTITION_COUNT).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: termLength, alignment: Self.FRAME_ALIGNMENT)
        }
        
        // 分配元数据缓冲区
        self.metaDataBuffer = UnsafeMutableRawPointer.allocate(byteCount: Self.LOG_META_DATA_LENGTH, alignment: Self.FRAME_ALIGNMENT)
        
        // 初始化元数据
        initializeMetaData()
    }
    
    deinit {
        // 释放缓冲区
        termBuffers.forEach { $0.deallocate() }
        metaDataBuffer.deallocate()
    }
    
    private func initializeMetaData() {
        // 初始化术语尾部计数器
        for i in 0..<Self.PARTITION_COUNT {
            let offset = Self.TERM_TAIL_COUNTERS_OFFSET + (i * 8)
            metaDataBuffer.advanced(by: offset).storeBytes(of: Int64(0), as: Int64.self)
        }
        
        // 初始化活动术语计数
        metaDataBuffer.advanced(by: Self.ACTIVE_TERM_COUNT_OFFSET).storeBytes(of: Int64(0), as: Int64.self)
        
        // 初始化连接状态
        metaDataBuffer.advanced(by: Self.IS_CONNECTED_OFFSET).storeBytes(of: Int32(0), as: Int32.self)
    }
    
    public func getActiveTerm() -> Int {
        let activeTermCount = metaDataBuffer.advanced(by: Self.ACTIVE_TERM_COUNT_OFFSET).load(as: Int64.self)
        return Int(activeTermCount) % Self.PARTITION_COUNT
    }
    
    public func getTailCounter(termId: Int) -> Int64 {
        let offset = Self.TERM_TAIL_COUNTERS_OFFSET + (termId * 8)
        return metaDataBuffer.advanced(by: offset).load(as: Int64.self)
    }
    
    public func setTailCounter(termId: Int, value: Int64) {
        let offset = Self.TERM_TAIL_COUNTERS_OFFSET + (termId * 8)
        metaDataBuffer.advanced(by: offset).storeBytes(of: value, as: Int64.self)
    }
}

/// Aeron发布者 - 按照真正的Aeron Publication设计
public class AeronPublication {
    // 发布结果状态码 - 按照Aeron规范
    public static let NOT_CONNECTED: Int64 = -1
    public static let BACK_PRESSURED: Int64 = -2
    public static let ADMIN_ACTION: Int64 = -3
    public static let CLOSED: Int64 = -4
    public static let MAX_POSITION_EXCEEDED: Int64 = -5
    
    private let streamId: Int32
    private let sessionId: Int32
    private let initialTermId: Int32
    private let termBufferLength: Int
    private let maxPayloadLength: Int
    private let maxMessageLength: Int
    private let positionBitsToShift: Int
    private let termIdMask: Int32
    
    private let logBufferDescriptor: AeronLogBufferDescriptor
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var isConnected = false
    
    // 位置跟踪 - Aeron核心机制
    private var position: Int64 = 0
    private var positionLimit: Int64 = 0
    
    public init(streamId: Int32, sessionId: Int32, initialTermId: Int32, termBufferLength: Int, host: String, port: UInt16) {
        self.streamId = streamId
        self.sessionId = sessionId
        self.initialTermId = initialTermId
        self.termBufferLength = termBufferLength
        self.maxPayloadLength = termBufferLength / 8 // Aeron规范
        self.maxMessageLength = termBufferLength / 4 // Aeron规范
        
        // 位置计算 - Aeron位操作优化
        self.positionBitsToShift = Int(log2(Double(termBufferLength)))
        self.termIdMask = Int32(termBufferLength - 1)
        
        // 创建日志缓冲区描述符
        self.logBufferDescriptor = AeronLogBufferDescriptor(
            termLength: termBufferLength,
            pageSize: AeronLogBufferDescriptor.MIN_PAGE_SIZE
        )
        
        // 建立网络连接
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        self.connection = NWConnection(to: endpoint, using: .udp)
        self.queue = DispatchQueue(label: "aeron-publication-\(streamId)-\(sessionId)")
    }
    
    public func connect() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.isConnected = true
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: AeronCoreError.connectionCancelled)
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
    
    /// 核心发布方法 - 按照Aeron Publication.offer()设计
    public func offer(_ buffer: Data, offset: Int = 0, length: Int? = nil) async -> Int64 {
        guard isConnected else {
            return Self.NOT_CONNECTED
        }
        
        let messageLength = length ?? buffer.count
        
        // 检查消息长度限制
        guard messageLength <= maxMessageLength else {
            return Self.MAX_POSITION_EXCEEDED
        }
        
        // 获取当前活动术语
        let activeTerm = logBufferDescriptor.getActiveTerm()
        let termBuffer = logBufferDescriptor.termBuffers[activeTerm]
        
        // 计算帧长度（包括32字节头部）
        let frameLength = AeronLogBufferDescriptor.FRAME_ALIGNMENT + messageLength
        let alignedFrameLength = (frameLength + AeronLogBufferDescriptor.FRAME_ALIGNMENT - 1) & ~(AeronLogBufferDescriptor.FRAME_ALIGNMENT - 1)
        
        // 获取当前尾部位置
        let tailCounter = logBufferDescriptor.getTailCounter(termId: activeTerm)
        let termOffset = Int(tailCounter) & (termBufferLength - 1)
        
        // 检查是否有足够空间
        if termOffset + alignedFrameLength > termBufferLength {
            return rotateToNextTerm(activeTerm)
        }
        
        // 写入帧头部 - 按照Aeron数据帧格式
        let frameHeader = createDataFrameHeader(
            frameLength: UInt32(frameLength),
            termOffset: UInt32(termOffset),
            streamId: streamId,
            sessionId: sessionId,
            termId: Int32(activeTerm) + initialTermId
        )
        
        // 写入数据到术语缓冲区
        termBuffer.advanced(by: termOffset).copyMemory(from: frameHeader.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! }, byteCount: AeronLogBufferDescriptor.FRAME_ALIGNMENT)
        
        // 写入消息数据
        buffer.withUnsafeBytes { bufferPtr in
            let sourcePtr = bufferPtr.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset)
            termBuffer.advanced(by: termOffset + AeronLogBufferDescriptor.FRAME_ALIGNMENT).copyMemory(from: sourcePtr, byteCount: messageLength)
        }
        
        // 更新尾部计数器
        let newTailCounter = tailCounter + Int64(alignedFrameLength)
        logBufferDescriptor.setTailCounter(termId: activeTerm, value: newTailCounter)
        
        // 发送到网络
        let frame = Data(bytesNoCopy: termBuffer.advanced(by: termOffset), count: alignedFrameLength, deallocator: .none)
        await sendFrame(frame)
        
        // 更新位置
        position = computePosition(termId: Int32(activeTerm) + initialTermId, termOffset: termOffset + alignedFrameLength)
        
        return Int64(alignedFrameLength)
    }
    
    /// 尝试声明空间 - Aeron零拷贝机制
    public func tryClaim(length: Int) async -> AeronBufferClaim? {
        guard isConnected else {
            return nil
        }
        
        let activeTerm = logBufferDescriptor.getActiveTerm()
        let termBuffer = logBufferDescriptor.termBuffers[activeTerm]
        
        let frameLength = AeronLogBufferDescriptor.FRAME_ALIGNMENT + length
        let alignedFrameLength = (frameLength + AeronLogBufferDescriptor.FRAME_ALIGNMENT - 1) & ~(AeronLogBufferDescriptor.FRAME_ALIGNMENT - 1)
        
        let tailCounter = logBufferDescriptor.getTailCounter(termId: activeTerm)
        let termOffset = Int(tailCounter) & (termBufferLength - 1)
        
        if termOffset + alignedFrameLength > termBufferLength {
            return nil
        }
        
        // 预写入帧头部
        let frameHeader = createDataFrameHeader(
            frameLength: UInt32(frameLength),
            termOffset: UInt32(termOffset),
            streamId: streamId,
            sessionId: sessionId,
            termId: Int32(activeTerm) + initialTermId
        )
        
        termBuffer.advanced(by: termOffset).copyMemory(from: frameHeader.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! }, byteCount: AeronLogBufferDescriptor.FRAME_ALIGNMENT)
        
        // 返回缓冲区声明
        return AeronBufferClaim(
            buffer: termBuffer.advanced(by: termOffset + AeronLogBufferDescriptor.FRAME_ALIGNMENT),
            length: length,
            onCommit: { [weak self] in
                guard let self = self else { return }
                
                // 更新尾部计数器
                let newTailCounter = tailCounter + Int64(alignedFrameLength)
                self.logBufferDescriptor.setTailCounter(termId: activeTerm, value: newTailCounter)
                
                // 发送到网络
                let frame = Data(bytesNoCopy: termBuffer.advanced(by: termOffset), count: alignedFrameLength, deallocator: .none)
                Task {
                    await self.sendFrame(frame)
                }
                
                // 更新位置
                self.position = self.computePosition(termId: Int32(activeTerm) + self.initialTermId, termOffset: termOffset + alignedFrameLength)
            }
        )
    }
    
    private func rotateToNextTerm(_ currentTerm: Int) -> Int64 {
        // 术语轮换逻辑
        let nextTerm = (currentTerm + 1) % AeronLogBufferDescriptor.PARTITION_COUNT
        logBufferDescriptor.setTailCounter(termId: nextTerm, value: 0)
        
        // 更新活动术语计数
        let activeTermCount = logBufferDescriptor.metaDataBuffer.advanced(by: AeronLogBufferDescriptor.ACTIVE_TERM_COUNT_OFFSET).load(as: Int64.self)
        logBufferDescriptor.metaDataBuffer.advanced(by: AeronLogBufferDescriptor.ACTIVE_TERM_COUNT_OFFSET).storeBytes(of: activeTermCount + 1, as: Int64.self)
        
        return Self.BACK_PRESSURED
    }
    
    private func computePosition(termId: Int32, termOffset: Int) -> Int64 {
        let termCount = Int64(termId - initialTermId)
        return (termCount << positionBitsToShift) + Int64(termOffset)
    }
    
    private func createDataFrameHeader(frameLength: UInt32, termOffset: UInt32, streamId: Int32, sessionId: Int32, termId: Int32) -> Data {
        var header = Data(count: AeronLogBufferDescriptor.FRAME_ALIGNMENT)
        
        header.withUnsafeMutableBytes { ptr in
            let basePtr = ptr.bindMemory(to: UInt8.self).baseAddress!
            
            // Aeron帧头格式 - 小端序
            basePtr.withMemoryRebound(to: UInt32.self, capacity: 8) { u32Ptr in
                u32Ptr[0] = frameLength.littleEndian
                u32Ptr[1] = UInt32(0x01).littleEndian  // 数据帧类型
                u32Ptr[2] = UInt32(sessionId).littleEndian
                u32Ptr[3] = UInt32(streamId).littleEndian
                u32Ptr[4] = UInt32(termId).littleEndian
                u32Ptr[5] = termOffset.littleEndian
                u32Ptr[6] = 0 // 保留字段
                u32Ptr[7] = 0 // 保留字段
            }
        }
        
        return header
    }
    
    private func sendFrame(_ frame: Data) async {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } catch {
            print("发送帧失败: \(error)")
        }
    }
    
    public func getPosition() -> Int64 {
        return position
    }
    
    public func getPositionLimit() -> Int64 {
        return positionLimit
    }
    
    public func isConnectedState() -> Bool {
        return isConnected
    }
    
    public func close() {
        connection.cancel()
        isConnected = false
    }
}

/// Aeron缓冲区声明 - 零拷贝机制
public class AeronBufferClaim {
    private let buffer: UnsafeMutableRawPointer
    private let length: Int
    private let onCommit: () -> Void
    
    init(buffer: UnsafeMutableRawPointer, length: Int, onCommit: @escaping () -> Void) {
        self.buffer = buffer
        self.length = length
        self.onCommit = onCommit
    }
    
    public func putBytes(_ data: Data, offset: Int = 0) {
        data.withUnsafeBytes { dataPtr in
            let sourcePtr = dataPtr.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset)
            buffer.copyMemory(from: sourcePtr, byteCount: min(data.count - offset, length))
        }
    }
    
    public func putInt64(_ value: Int64, offset: Int = 0) {
        buffer.advanced(by: offset).storeBytes(of: value.littleEndian, as: Int64.self)
    }
    
    public func putInt32(_ value: Int32, offset: Int = 0) {
        buffer.advanced(by: offset).storeBytes(of: value.littleEndian, as: Int32.self)
    }
    
    public func commit() {
        onCommit()
    }
    
    public func abort() {
        // 标记缓冲区为未使用
        buffer.storeBytes(of: UInt32(0), as: UInt32.self)
    }
}

/// Aeron核心错误类型
public enum AeronCoreError: Error {
    case connectionCancelled
    case bufferFull
    case invalidLength
    case notConnected
}