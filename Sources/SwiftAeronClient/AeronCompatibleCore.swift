import Foundation
import Network

// MARK: - Aeron Compatible Publication (与aeron-rs完全兼容)

public class AeronCompatiblePublication {
    private let streamId: UInt32
    private let sessionId: UInt32
    private let initialTermId: UInt32
    private let termBufferLength: Int
    private let positionBitsToShift: Int
    
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var isConnected = false
    
    // Term buffers - 按照Aeron规范使用单个活动术语
    private var termOffset: UInt32 = 0
    private var currentTermId: UInt32
    
    // Flow control
    private var receiverWindow: UInt32 = 0
    private var lastStatusMessageTime = Date()
    
    public init(streamId: UInt32, sessionId: UInt32, termBufferLength: Int = AeronProtocolSpec.TERM_DEFAULT_LENGTH, host: String, port: UInt16) {
        self.streamId = streamId
        self.sessionId = sessionId
        self.initialTermId = UInt32.random(in: 1...UInt32.max) // 随机初始术语ID
        self.currentTermId = self.initialTermId
        self.termBufferLength = termBufferLength
        self.positionBitsToShift = AeronProtocolSpec.positionBitsToShift(termBufferLength: termBufferLength)
        
        // 创建UDP连接
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        self.connection = NWConnection(to: endpoint, using: .udp)
        self.queue = DispatchQueue(label: "aeron-compatible-publication")
    }
    
    public func connect() async throws {
        print("🔌 连接到Aeron兼容端点: \(streamId):\(sessionId)")
        
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
    
    // MARK: - Setup Frame (建立连接)
    
    private func sendSetupFrame() async {
        let setupHeader = AeronSetupHeader(
            sessionId: sessionId,
            streamId: streamId,
            initialTermId: initialTermId,
            termLength: UInt32(termBufferLength)
        )
        
        let setupData = setupHeader.toBytes()
        await sendUDPFrame(setupData)
        print("📋 发送Setup帧: 流\(streamId), 会话\(sessionId), 初始术语\(initialTermId)")
    }
    
    // MARK: - Data Publication (按照Aeron规范)
    
    public func offer(_ buffer: Data) async -> Int64 {
        guard isConnected else { return -1 }
        
        let messageLength = buffer.count
        let frameLength = AeronProtocolSpec.DATA_HEADER_LENGTH + messageLength
        let alignedFrameLength = alignFrameLength(frameLength)
        
        // 检查术语缓冲区空间
        if Int(termOffset) + alignedFrameLength > termBufferLength {
            // 轮换到下一个术语
            currentTermId += 1
            termOffset = 0
        }
        
        // 创建数据帧头
        let dataHeader = AeronDataHeader(
            frameLength: UInt32(frameLength),
            termOffset: termOffset,
            sessionId: sessionId,
            streamId: streamId,
            termId: currentTermId
        )
        
        // 构建完整帧
        var frame = dataHeader.toBytes()
        frame.append(buffer)
        
        // 填充到对齐边界
        let paddingNeeded = alignedFrameLength - frameLength
        if paddingNeeded > 0 {
            frame.append(Data(repeating: 0, count: paddingNeeded))
        }
        
        await sendUDPFrame(frame)
        
        // 更新术语偏移
        termOffset += UInt32(alignedFrameLength)
        
        // 计算位置
        let position = AeronProtocolSpec.computePosition(
            termId: Int32(currentTermId - initialTermId),
            termOffset: Int32(termOffset),
            positionBitsToShift: positionBitsToShift
        )
        
        return position
    }
    
    // MARK: - Status Message Handling (流控制)
    
    private func startStatusMessageHandler() async {
        // 监听状态消息用于流控制
        receiveStatusMessages()
    }
    
    private func receiveStatusMessages() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                Task {
                    await self.handleStatusMessage(data)
                }
            }
            
            if let error = error {
                print("❌ 接收状态消息错误: \(error)")
                return
            }
            
            if !isComplete {
                self.receiveStatusMessages()
            }
        }
    }
    
    private func handleStatusMessage(_ data: Data) async {
        guard data.count >= AeronProtocolSpec.STATUS_MESSAGE_HEADER_LENGTH else { return }
        
        let type = UInt16.fromLittleEndianBytes(data, offset: 6)
        
        if type == AeronProtocolSpec.SM_HEADER_TYPE {
            // 解析状态消息
            let sessionId = UInt32.fromLittleEndianBytes(data, offset: 8)
            let streamId = UInt32.fromLittleEndianBytes(data, offset: 12)
            let consumptionTermId = UInt32.fromLittleEndianBytes(data, offset: 16)
            let consumptionTermOffset = UInt32.fromLittleEndianBytes(data, offset: 20)
            let receiverWindow = UInt32.fromLittleEndianBytes(data, offset: 24)
            
            if sessionId == self.sessionId && streamId == self.streamId {
                self.receiverWindow = receiverWindow
                self.lastStatusMessageTime = Date()
                print("📊 收到状态消息: 窗口=\(receiverWindow), 术语=\(consumptionTermId), 偏移=\(consumptionTermOffset)")
            }
        }
    }
    
    // MARK: - Utility Methods
    
    private func alignFrameLength(_ length: Int) -> Int {
        return (length + AeronProtocolSpec.FRAME_ALIGNMENT - 1) & ~(AeronProtocolSpec.FRAME_ALIGNMENT - 1)
    }
    
    private func sendUDPFrame(_ frame: Data) async {
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
            print("❌ 发送帧失败: \(error)")
        }
    }
    
    public func close() {
        connection.cancel()
        isConnected = false
    }
    
    public func getPosition() -> Int64 {
        return AeronProtocolSpec.computePosition(
            termId: Int32(currentTermId - initialTermId),
            termOffset: Int32(termOffset),
            positionBitsToShift: positionBitsToShift
        )
    }
}

// MARK: - Aeron Compatible Subscription (与aeron-rs完全兼容)

public class AeronCompatibleSubscription {
    private let streamId: UInt32
    private let sessionId: UInt32?  // nil表示订阅所有会话
    
    private let listener: NWListener
    private let queue: DispatchQueue
    private var isListening = false
    
    // 接收状态跟踪
    private var publications: [UInt32: PublicationState] = [:] // sessionId -> state
    private var lastPositions: [UInt32: Int64] = [:]
    
    // Fragment handler
    public var fragmentHandler: ((Data, UInt32, UInt32, Int64) -> Void)?
    
    struct PublicationState {
        var initialTermId: UInt32
        var termBufferLength: Int
        var positionBitsToShift: Int
        var lastTermId: UInt32
        var lastTermOffset: UInt32
        var receivedFrames: Set<String> = [] // 防重复
        
        init(initialTermId: UInt32, termBufferLength: Int) {
            self.initialTermId = initialTermId
            self.termBufferLength = termBufferLength
            self.positionBitsToShift = AeronProtocolSpec.positionBitsToShift(termBufferLength: termBufferLength)
            self.lastTermId = initialTermId
            self.lastTermOffset = 0
        }
    }
    
    public init(streamId: UInt32, sessionId: UInt32? = nil, port: UInt16) throws {
        self.streamId = streamId
        self.sessionId = sessionId
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.queue = DispatchQueue(label: "aeron-compatible-subscription")
    }
    
    public func startListening() async throws {
        print("🎧 启动Aeron兼容订阅: 流\(streamId), 端口\(listener.port!)")
        
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
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveFrames(from: connection)
    }
    
    private func receiveFrames(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                Task {
                    await self.processFrame(data, connection: connection)
                }
            }
            
            if let error = error {
                print("❌ 接收帧错误: \(error)")
                return
            }
            
            if !isComplete {
                self.receiveFrames(from: connection)
            }
        }
    }
    
    private func processFrame(_ data: Data, connection: NWConnection) async {
        guard data.count >= 8 else { return } // 最小帧头
        
        let frameLength = UInt32.fromLittleEndianBytes(data, offset: 0)
        let type = UInt16.fromLittleEndianBytes(data, offset: 6)
        
        switch type {
        case AeronProtocolSpec.SETUP_HEADER_TYPE:
            await handleSetupFrame(data, connection: connection)
            
        case AeronProtocolSpec.DATA_HEADER_TYPE:
            await handleDataFrame(data, connection: connection)
            
        default:
            print("⚠️ 未知帧类型: \(type)")
        }
    }
    
    private func handleSetupFrame(_ data: Data, connection: NWConnection) async {
        guard data.count >= AeronProtocolSpec.SETUP_HEADER_LENGTH else { return }
        
        let sessionId = UInt32.fromLittleEndianBytes(data, offset: 12)
        let streamId = UInt32.fromLittleEndianBytes(data, offset: 16)
        let initialTermId = UInt32.fromLittleEndianBytes(data, offset: 20)
        let termLength = Int(UInt32.fromLittleEndianBytes(data, offset: 28))
        
        // 检查是否是我们感兴趣的流
        guard streamId == self.streamId else { return }
        if let targetSessionId = self.sessionId, targetSessionId != sessionId { return }
        
        // 创建或更新发布状态
        publications[sessionId] = PublicationState(
            initialTermId: initialTermId,
            termBufferLength: termLength
        )
        
        print("📋 收到Setup帧: 流\(streamId), 会话\(sessionId), 初始术语\(initialTermId), 术语长度\(termLength)")
        
        // 发送初始状态消息
        await sendStatusMessage(to: connection, sessionId: sessionId, streamId: streamId, termId: initialTermId, termOffset: 0)
    }
    
    private func handleDataFrame(_ data: Data, connection: NWConnection) async {
        guard let dataHeader = AeronDataHeader.fromBytes(data) else { return }
        
        // 检查流和会话匹配
        guard dataHeader.streamId == self.streamId else { return }
        if let targetSessionId = self.sessionId, targetSessionId != dataHeader.sessionId { return }
        
        guard var pubState = publications[dataHeader.sessionId] else {
            print("⚠️ 收到数据帧但没有对应的Setup: 会话\(dataHeader.sessionId)")
            return
        }
        
        // 防重复检查
        let frameKey = "\(dataHeader.termId):\(dataHeader.termOffset)"
        if pubState.receivedFrames.contains(frameKey) {
            print("🔄 重复帧: \(frameKey)")
            return
        }
        pubState.receivedFrames.insert(frameKey)
        
        // 提取有效载荷
        let payloadOffset = AeronProtocolSpec.DATA_HEADER_LENGTH
        guard data.count > payloadOffset else { return }
        
        let payload = data.subdata(in: payloadOffset..<Int(dataHeader.frameLength))
        
        // 计算位置
        let relativeTermId = Int32(dataHeader.termId - pubState.initialTermId)
        let position = AeronProtocolSpec.computePosition(
            termId: relativeTermId,
            termOffset: Int32(dataHeader.termOffset),
            positionBitsToShift: pubState.positionBitsToShift
        )
        
        // 更新状态
        pubState.lastTermId = dataHeader.termId
        pubState.lastTermOffset = dataHeader.termOffset + UInt32(payload.count)
        publications[dataHeader.sessionId] = pubState
        lastPositions[dataHeader.sessionId] = position
        
        print("📨 收到数据帧: 会话\(dataHeader.sessionId), 术语\(dataHeader.termId), 偏移\(dataHeader.termOffset), 大小\(payload.count), 位置\(position)")
        
        // 调用fragment handler
        fragmentHandler?(payload, dataHeader.sessionId, dataHeader.streamId, position)
        
        // 发送状态消息确认
        await sendStatusMessage(
            to: connection,
            sessionId: dataHeader.sessionId,
            streamId: dataHeader.streamId,
            termId: dataHeader.termId,
            termOffset: dataHeader.termOffset + UInt32(payload.count)
        )
    }
    
    private func sendStatusMessage(to connection: NWConnection, sessionId: UInt32, streamId: UInt32, termId: UInt32, termOffset: UInt32) async {
        let statusMessage = AeronStatusMessageHeader(
            sessionId: sessionId,
            streamId: streamId,
            termId: termId,
            termOffset: termOffset,
            receiverWindow: UInt32(termBufferLength) // 设置接收窗口
        )
        
        let statusData = statusMessage.toBytes()
        
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: statusData, completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
            print("📊 发送状态消息: 会话\(sessionId), 术语\(termId), 偏移\(termOffset)")
        } catch {
            print("❌ 发送状态消息失败: \(error)")
        }
    }
    
    public func poll(limit: Int = 10) -> Int {
        // 在实际实现中，这里会处理缓冲的片段
        // 当前实现使用实时处理，所以返回0
        return 0
    }
    
    public var termBufferLength: Int {
        return AeronProtocolSpec.TERM_DEFAULT_LENGTH
    }
    
    public func getLastPosition(sessionId: UInt32) -> Int64? {
        return lastPositions[sessionId]
    }
}