import Foundation
import Network

/// Aeron订阅者 - 按照真正的Aeron Subscription设计
public class AeronSubscription {
    private let streamId: Int32
    private let listener: NWListener
    private let queue: DispatchQueue
    private var isListening = false
    
    // 图像构建器 - Aeron核心机制
    private var imageBuilders: [Int32: AeronImageBuilder] = [:]
    private var images: [Int32: AeronImage] = [:]
    
    // 处理器
    public var availableImageHandler: ((AeronImage) -> Void)?
    public var unavailableImageHandler: ((AeronImage) -> Void)?
    public var fragmentHandler: ((Data, Int32, Int32, Int64) -> Void)?
    
    public init(streamId: Int32, port: UInt16) throws {
        self.streamId = streamId
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.queue = DispatchQueue(label: "aeron-subscription-\(streamId)")
    }
    
    public func startListening() async throws {
        listener.newConnectionHandler = { connection in
            self.handleConnection(connection)
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
    
    public func stopListening() {
        listener.cancel()
        isListening = false
        
        // 清理所有图像
        for (_, image) in images {
            unavailableImageHandler?(image)
        }
        images.removeAll()
        imageBuilders.removeAll()
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveData(from: connection)
    }
    
    private func receiveData(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                Task {
                    await self.processAeronFrame(data, connection: connection)
                }
            }
            
            if let error = error {
                print("接收错误: \(error)")
                return
            }
            
            if !isComplete {
                self.receiveData(from: connection)
            }
        }
    }
    
    private func processAeronFrame(_ data: Data, connection: NWConnection) async {
        guard data.count >= AeronLogBufferDescriptor.FRAME_ALIGNMENT else {
            print("帧太短: \(data.count)")
            return
        }
        
        // 解析Aeron帧头
        let frameHeader = data.withUnsafeBytes { ptr -> AeronFrameHeader in
            let basePtr = ptr.bindMemory(to: UInt8.self).baseAddress!
            return basePtr.withMemoryRebound(to: UInt32.self, capacity: 8) { u32Ptr in
                return AeronFrameHeader(
                    frameLength: u32Ptr[0].littleEndian,
                    frameType: u32Ptr[1].littleEndian,
                    sessionId: Int32(u32Ptr[2].littleEndian),
                    streamId: Int32(u32Ptr[3].littleEndian),
                    termId: Int32(u32Ptr[4].littleEndian),
                    termOffset: u32Ptr[5].littleEndian,
                    reserved1: u32Ptr[6].littleEndian,
                    reserved2: u32Ptr[7].littleEndian
                )
            }
        }
        
        // 验证流ID
        guard frameHeader.streamId == streamId else {
            return
        }
        
        // 获取或创建图像
        let image = await getOrCreateImage(sessionId: frameHeader.sessionId, termId: frameHeader.termId, connection: connection)
        
        // 处理帧
        await image.insertFrame(data, frameHeader: frameHeader)
        
        // 轮询片段
        await pollFragments(image: image)
    }
    
    private func getOrCreateImage(sessionId: Int32, termId: Int32, connection: NWConnection) async -> AeronImage {
        if let existingImage = images[sessionId] {
            return existingImage
        }
        
        // 获取或创建图像构建器
        let imageBuilder: AeronImageBuilder
        if let existingBuilder = imageBuilders[sessionId] {
            imageBuilder = existingBuilder
        } else {
            imageBuilder = AeronImageBuilder(
                sessionId: sessionId,
                streamId: streamId,
                initialTermId: termId,
                termBufferLength: AeronLogBufferDescriptor.MIN_TERM_LENGTH
            )
            imageBuilders[sessionId] = imageBuilder
        }
        
        // 检查是否可以创建图像
        if imageBuilder.canBuildImage() {
            let image = imageBuilder.buildImage()
            images[sessionId] = image
            imageBuilders.removeValue(forKey: sessionId)
            
            // 通知新图像可用
            availableImageHandler?(image)
            
            return image
        }
        
        // 返回临时图像（用于收集初始数据）
        return imageBuilder.getTemporaryImage()
    }
    
    private func pollFragments(image: AeronImage) async {
        let fragments = await image.poll(limit: 10) // 每次轮询最多10个片段
        
        for fragment in fragments {
            fragmentHandler?(fragment.data, fragment.sessionId, fragment.streamId, fragment.position)
        }
    }
    
    public func poll(limit: Int = 10) async -> Int {
        var fragmentCount = 0
        
        for (_, image) in images {
            let fragments = await image.poll(limit: limit - fragmentCount)
            
            for fragment in fragments {
                fragmentHandler?(fragment.data, fragment.sessionId, fragment.streamId, fragment.position)
                fragmentCount += 1
                
                if fragmentCount >= limit {
                    break
                }
            }
            
            if fragmentCount >= limit {
                break
            }
        }
        
        return fragmentCount
    }
    
    public func getImages() -> [AeronImage] {
        return Array(images.values)
    }
    
    public func isConnected() -> Bool {
        return isListening
    }
}

/// Aeron图像构建器
public class AeronImageBuilder {
    private let sessionId: Int32
    private let streamId: Int32
    private let initialTermId: Int32
    private let termBufferLength: Int
    
    private var receivedTermIds: Set<Int32> = []
    private var setupComplete = false
    
    init(sessionId: Int32, streamId: Int32, initialTermId: Int32, termBufferLength: Int) {
        self.sessionId = sessionId
        self.streamId = streamId
        self.initialTermId = initialTermId
        self.termBufferLength = termBufferLength
    }
    
    func addTermId(_ termId: Int32) {
        receivedTermIds.insert(termId)
        
        // 检查是否收到足够的术语ID来建立图像
        if receivedTermIds.count >= 1 {
            setupComplete = true
        }
    }
    
    func canBuildImage() -> Bool {
        return setupComplete
    }
    
    func buildImage() -> AeronImage {
        return AeronImage(
            sessionId: sessionId,
            streamId: streamId,
            initialTermId: initialTermId,
            termBufferLength: termBufferLength
        )
    }
    
    func getTemporaryImage() -> AeronImage {
        return AeronImage(
            sessionId: sessionId,
            streamId: streamId,
            initialTermId: initialTermId,
            termBufferLength: termBufferLength
        )
    }
}

/// Aeron图像 - 表示单个发布者的流
public class AeronImage {
    public let sessionId: Int32
    public let streamId: Int32
    public let initialTermId: Int32
    public let termBufferLength: Int
    
    private let logBufferDescriptor: AeronLogBufferDescriptor
    private var position: Int64 = 0
    private var fragmentQueue: [AeronFragment] = []
    private let fragmentQueueLock = NSLock()
    
    // 重建器 - 处理术语重建
    private var rebuilders: [Int32: AeronTermRebuilder] = [:]
    
    init(sessionId: Int32, streamId: Int32, initialTermId: Int32, termBufferLength: Int) {
        self.sessionId = sessionId
        self.streamId = streamId
        self.initialTermId = initialTermId
        self.termBufferLength = termBufferLength
        
        self.logBufferDescriptor = AeronLogBufferDescriptor(
            termLength: termBufferLength,
            pageSize: AeronLogBufferDescriptor.MIN_PAGE_SIZE
        )
    }
    
    func insertFrame(_ data: Data, frameHeader: AeronFrameHeader) async {
        let termIndex = getTermIndex(termId: frameHeader.termId)
        
        // 获取或创建术语重建器
        let rebuilder: AeronTermRebuilder
        if let existingRebuilder = rebuilders[frameHeader.termId] {
            rebuilder = existingRebuilder
        } else {
            rebuilder = AeronTermRebuilder(
                termBuffer: logBufferDescriptor.termBuffers[termIndex],
                termId: frameHeader.termId,
                termLength: termBufferLength
            )
            rebuilders[frameHeader.termId] = rebuilder
        }
        
        // 插入帧到重建器
        let fragments = await rebuilder.insertFrame(data, frameHeader: frameHeader)
        
        // 将完成的片段添加到队列
        await withCheckedContinuation { continuation in
            fragmentQueueLock.lock()
            fragmentQueue.append(contentsOf: fragments)
            fragmentQueueLock.unlock()
            continuation.resume()
        }
    }
    
    func poll(limit: Int) async -> [AeronFragment] {
        return await withCheckedContinuation { continuation in
            fragmentQueueLock.lock()
            let pollCount = min(limit, fragmentQueue.count)
            let polledFragments = Array(fragmentQueue.prefix(pollCount))
            fragmentQueue.removeFirst(pollCount)
            fragmentQueueLock.unlock()
            continuation.resume(returning: polledFragments)
        }
    }
    
    private func getTermIndex(termId: Int32) -> Int {
        let termCount = termId - initialTermId
        return Int(termCount) % AeronLogBufferDescriptor.PARTITION_COUNT
    }
    
    public func getPosition() -> Int64 {
        return position
    }
    
    public func isClosed() -> Bool {
        return false // 简化实现
    }
}

/// Aeron术语重建器
public class AeronTermRebuilder: @unchecked Sendable {
    private let termBuffer: UnsafeMutableRawPointer
    private let termId: Int32
    private let termLength: Int
    
    private var completedPosition: Int = 0
    private var gaps: [Range<Int>] = []
    private let lock = NSLock()
    
    init(termBuffer: UnsafeMutableRawPointer, termId: Int32, termLength: Int) {
        self.termBuffer = termBuffer
        self.termId = termId
        self.termLength = termLength
    }
    
    func insertFrame(_ data: Data, frameHeader: AeronFrameHeader) async -> [AeronFragment] {
        return await withCheckedContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            
            let termOffset = Int(frameHeader.termOffset)
            let frameLength = Int(frameHeader.frameLength)
            
            // 检查帧是否在有效范围内
            guard termOffset + frameLength <= termLength else {
                continuation.resume(returning: [])
                return
            }
            
            // 将帧数据复制到术语缓冲区
            data.withUnsafeBytes { dataPtr in
                termBuffer.advanced(by: termOffset).copyMemory(from: dataPtr.bindMemory(to: UInt8.self).baseAddress!, byteCount: frameLength)
            }
            
            // 检查是否填补了间隙或扩展了完成位置
            let fragments = processCompletedFragments(newFrameOffset: termOffset, newFrameLength: frameLength)
            continuation.resume(returning: fragments)
        }
    }
    
    private func processCompletedFragments(newFrameOffset: Int, newFrameLength: Int) -> [AeronFragment] {
        var fragments: [AeronFragment] = []
        
        // 检查新帧是否连接到已完成位置
        if newFrameOffset == completedPosition {
            var scanPosition = completedPosition
            
            // 扫描连续的帧
            while scanPosition < termLength {
                // 读取帧头检查帧是否完整
                guard scanPosition + AeronLogBufferDescriptor.FRAME_ALIGNMENT <= termLength else {
                    break
                }
                
                let frameHeader = readFrameHeader(at: scanPosition)
                
                // 检查帧是否完整
                if frameHeader.frameLength == 0 || scanPosition + Int(frameHeader.frameLength) > termLength {
                    break
                }
                
                // 创建片段
                let payloadOffset = scanPosition + AeronLogBufferDescriptor.FRAME_ALIGNMENT
                let payloadLength = Int(frameHeader.frameLength) - AeronLogBufferDescriptor.FRAME_ALIGNMENT
                
                if payloadLength > 0 {
                    let payloadData = Data(bytesNoCopy: termBuffer.advanced(by: payloadOffset), count: payloadLength, deallocator: .none)
                    
                    let fragment = AeronFragment(
                        data: payloadData,
                        sessionId: frameHeader.sessionId,
                        streamId: frameHeader.streamId,
                        termId: frameHeader.termId,
                        termOffset: frameHeader.termOffset,
                        position: computePosition(termId: frameHeader.termId, termOffset: Int(frameHeader.termOffset))
                    )
                    
                    fragments.append(fragment)
                }
                
                scanPosition += Int(frameHeader.frameLength)
            }
            
            completedPosition = scanPosition
        }
        
        return fragments
    }
    
    private func readFrameHeader(at offset: Int) -> AeronFrameHeader {
        return termBuffer.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 8) { u32Ptr in
            return AeronFrameHeader(
                frameLength: u32Ptr[0].littleEndian,
                frameType: u32Ptr[1].littleEndian,
                sessionId: Int32(u32Ptr[2].littleEndian),
                streamId: Int32(u32Ptr[3].littleEndian),
                termId: Int32(u32Ptr[4].littleEndian),
                termOffset: u32Ptr[5].littleEndian,
                reserved1: u32Ptr[6].littleEndian,
                reserved2: u32Ptr[7].littleEndian
            )
        }
    }
    
    private func computePosition(termId: Int32, termOffset: Int) -> Int64 {
        let termCount = Int64(termId)
        let positionBitsToShift = Int64(log2(Double(termLength)))
        return (termCount << positionBitsToShift) + Int64(termOffset)
    }
}

/// Aeron帧头结构
public struct AeronFrameHeader {
    public let frameLength: UInt32
    public let frameType: UInt32
    public let sessionId: Int32
    public let streamId: Int32
    public let termId: Int32
    public let termOffset: UInt32
    public let reserved1: UInt32
    public let reserved2: UInt32
}

/// Aeron片段
public struct AeronFragment {
    public let data: Data
    public let sessionId: Int32
    public let streamId: Int32
    public let termId: Int32
    public let termOffset: UInt32
    public let position: Int64
}