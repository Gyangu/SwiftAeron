import Foundation
import Network

/// 完整的Aeron可靠性协议实现
public class ReliableAeronClient {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var isConnected = false
    
    // 可靠性状态管理
    private var sequenceNumber: UInt32 = 0
    private var pendingMessages: [UInt32: PendingMessage] = [:]
    private var receivedSequences: Set<UInt32> = []
    private var lastReceivedSequence: UInt32 = 0
    private var flowControlWindow: UInt32 = 1000 // 发送窗口大小
    private var sendBuffer: [BufferedMessage] = []
    
    // 定时器和状态
    private var heartbeatTimer: Timer?
    private var retransmissionTimer: Timer?
    private let retransmissionTimeoutMs: UInt32 = 100
    private let heartbeatIntervalMs: UInt32 = 1000
    
    // Aeron协议常量
    private let HEADER_LENGTH: Int = 32
    private let FRAME_ALIGNMENT: Int = 32
    
    // 帧类型
    public enum FrameType: UInt16 {
        case data = 0x01
        case ack = 0x02
        case nak = 0x03
        case heartbeat = 0x04
        case flowControl = 0x05
    }
    
    struct PendingMessage {
        let data: Data
        let timestamp: Date
        let retryCount: Int
        let sessionId: UInt32
        let streamId: UInt32
    }
    
    struct BufferedMessage {
        let data: Data
        let sessionId: UInt32
        let streamId: UInt32
    }
    
    public init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        connection = NWConnection(to: endpoint, using: .udp)
        queue = DispatchQueue(label: "reliable-aeron-client")
    }
    
    public func connect() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.isConnected = true
                    self.startHeartbeat()
                    self.startRetransmissionCheck()
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: AeronError.connectionCancelled)
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
    
    public func sendReliable(_ data: Data, sessionId: UInt32 = 1, streamId: UInt32 = 1001) async throws {
        guard isConnected else {
            throw AeronError.notConnected
        }
        
        // 流量控制检查
        while pendingMessages.count >= flowControlWindow {
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        
        let seqNum = sequenceNumber
        sequenceNumber += 1
        
        // 创建数据帧
        let frame = try createReliableDataFrame(data: data, sequenceNumber: seqNum, sessionId: sessionId, streamId: streamId)
        
        // 保存到待确认列表
        pendingMessages[seqNum] = PendingMessage(
            data: data,
            timestamp: Date(),
            retryCount: 0,
            sessionId: sessionId,
            streamId: streamId
        )
        
        try await sendFrame(frame)
    }
    
    private func createReliableDataFrame(data: Data, sequenceNumber: UInt32, sessionId: UInt32, streamId: UInt32) throws -> Data {
        var frame = Data()
        
        let frameLength = HEADER_LENGTH + data.count
        let frameType = FrameType.data.rawValue
        let flags: UInt8 = 0x80 // Begin and End flags
        let version: UInt8 = 0x01
        let termId: UInt32 = 0
        let termOffset: UInt32 = 0
        
        // Aeron帧头 (32字节)
        frame.append(withUnsafeBytes(of: UInt32(frameLength).littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: frameType.littleEndian) { Data($0) })
        frame.append(flags)
        frame.append(version)
        frame.append(withUnsafeBytes(of: sessionId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: streamId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: termId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: termOffset.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: sequenceNumber.littleEndian) { Data($0) }) // 序列号
        
        // 填充到32字节对齐
        let paddingNeeded = HEADER_LENGTH - frame.count
        if paddingNeeded > 0 {
            frame.append(Data(repeating: 0, count: paddingNeeded))
        }
        
        // 添加数据
        frame.append(data)
        
        // 确保帧对齐
        let totalPadding = (FRAME_ALIGNMENT - (frame.count % FRAME_ALIGNMENT)) % FRAME_ALIGNMENT
        if totalPadding > 0 {
            frame.append(Data(repeating: 0, count: totalPadding))
        }
        
        return frame
    }
    
    private func createAckFrame(sequenceNumber: UInt32, sessionId: UInt32 = 1, streamId: UInt32 = 1001) throws -> Data {
        var frame = Data()
        
        let frameLength = HEADER_LENGTH
        let frameType = FrameType.ack.rawValue
        let flags: UInt8 = 0x00
        let version: UInt8 = 0x01
        let termId: UInt32 = 0
        let termOffset: UInt32 = 0
        
        frame.append(withUnsafeBytes(of: UInt32(frameLength).littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: frameType.littleEndian) { Data($0) })
        frame.append(flags)
        frame.append(version)
        frame.append(withUnsafeBytes(of: sessionId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: streamId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: termId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: termOffset.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: sequenceNumber.littleEndian) { Data($0) })
        
        // 填充到32字节
        let paddingNeeded = HEADER_LENGTH - frame.count
        if paddingNeeded > 0 {
            frame.append(Data(repeating: 0, count: paddingNeeded))
        }
        
        return frame
    }
    
    private func createHeartbeatFrame(sessionId: UInt32 = 1, streamId: UInt32 = 1001) throws -> Data {
        var frame = Data()
        
        let frameLength = HEADER_LENGTH
        let frameType = FrameType.heartbeat.rawValue
        let flags: UInt8 = 0x00
        let version: UInt8 = 0x01
        let termId: UInt32 = 0
        let termOffset: UInt32 = 0
        let timestamp = UInt32(Date().timeIntervalSince1970 * 1000) // ms
        
        frame.append(withUnsafeBytes(of: UInt32(frameLength).littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: frameType.littleEndian) { Data($0) })
        frame.append(flags)
        frame.append(version)
        frame.append(withUnsafeBytes(of: sessionId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: streamId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: termId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: termOffset.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: timestamp.littleEndian) { Data($0) })
        
        let paddingNeeded = HEADER_LENGTH - frame.count
        if paddingNeeded > 0 {
            frame.append(Data(repeating: 0, count: paddingNeeded))
        }
        
        return frame
    }
    
    private func sendFrame(_ frame: Data) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    // MARK: - 可靠性机制
    
    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Double(heartbeatIntervalMs) / 1000.0, repeats: true) { _ in
            Task {
                do {
                    let heartbeatFrame = try self.createHeartbeatFrame()
                    try await self.sendFrame(heartbeatFrame)
                } catch {
                    print("Heartbeat failed: \(error)")
                }
            }
        }
    }
    
    private func startRetransmissionCheck() {
        retransmissionTimer = Timer.scheduledTimer(withTimeInterval: Double(retransmissionTimeoutMs) / 1000.0, repeats: true) { _ in
            Task {
                await self.checkRetransmissions()
            }
        }
    }
    
    private func checkRetransmissions() async {
        let now = Date()
        let timeout = TimeInterval(retransmissionTimeoutMs) / 1000.0
        
        var toRetransmit: [UInt32] = []
        
        for (seqNum, pending) in pendingMessages {
            if now.timeIntervalSince(pending.timestamp) > timeout {
                toRetransmit.append(seqNum)
            }
        }
        
        for seqNum in toRetransmit {
            await retransmitMessage(seqNum)
        }
    }
    
    private func retransmitMessage(_ sequenceNumber: UInt32) async {
        guard let pending = pendingMessages[sequenceNumber] else { return }
        
        // 最多重传5次
        if pending.retryCount >= 5 {
            print("Message \(sequenceNumber) dropped after 5 retries")
            pendingMessages.removeValue(forKey: sequenceNumber)
            return
        }
        
        do {
            let frame = try createReliableDataFrame(
                data: pending.data,
                sequenceNumber: sequenceNumber,
                sessionId: pending.sessionId,
                streamId: pending.streamId
            )
            
            try await sendFrame(frame)
            
            // 更新重传信息
            pendingMessages[sequenceNumber] = PendingMessage(
                data: pending.data,
                timestamp: Date(),
                retryCount: pending.retryCount + 1,
                sessionId: pending.sessionId,
                streamId: pending.streamId
            )
            
            print("Retransmitted message \(sequenceNumber) (retry \(pending.retryCount + 1))")
            
        } catch {
            print("Retransmission failed for \(sequenceNumber): \(error)")
        }
    }
    
    public func handleAck(_ sequenceNumber: UInt32) {
        pendingMessages.removeValue(forKey: sequenceNumber)
        print("ACK received for sequence \(sequenceNumber)")
    }
    
    public func disconnect() {
        heartbeatTimer?.invalidate()
        retransmissionTimer?.invalidate()
        connection.cancel()
        isConnected = false
    }
    
    // MARK: - 统计信息
    
    public func getStatistics() -> ReliabilityStatistics {
        return ReliabilityStatistics(
            pendingMessages: pendingMessages.count,
            sequenceNumber: sequenceNumber,
            receivedSequences: receivedSequences.count,
            isConnected: isConnected
        )
    }
}

// MARK: - 接收端可靠性实现

public class ReliableAeronReceiver {
    private let listener: NWListener
    private let queue: DispatchQueue
    private var isListening = false
    
    // 可靠性状态
    private var expectedSequence: UInt32 = 0
    private var receivedSequences: Set<UInt32> = []
    private var outOfOrderBuffer: [UInt32: Data] = [:]
    
    public var onDataReceived: ((Data, UInt32, UInt32, UInt32) -> Void)? // data, seqNum, sessionId, streamId
    public var onFrameReceived: ((ReliableAeronClient.FrameType, UInt32, UInt32, UInt32) -> Void)? // frameType, seqNum, sessionId, streamId
    
    public init(port: UInt16) throws {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        queue = DispatchQueue(label: "reliable-aeron-receiver")
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
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveData(from: connection)
    }
    
    private func receiveData(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                Task {
                    await self.processReliableFrame(data, connection: connection)
                }
            }
            
            if let error = error {
                print("Receive error: \(error)")
                return
            }
            
            if !isComplete {
                self.receiveData(from: connection)
            }
        }
    }
    
    private func processReliableFrame(_ data: Data, connection: NWConnection) async {
        let headerLength = 32
        
        guard data.count >= headerLength else {
            print("Frame too short: \(data.count)")
            return
        }
        
        // 解析帧头
        let _frameLength = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let frameType = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }.littleEndian
        let sessionId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }.littleEndian
        let streamId = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }.littleEndian
        let sequenceNumber = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }.littleEndian
        
        guard let frameTypeEnum = ReliableAeronClient.FrameType(rawValue: frameType) else {
            print("Unknown frame type: \(frameType)")
            return
        }
        
        onFrameReceived?(frameTypeEnum, sequenceNumber, sessionId, streamId)
        
        switch frameTypeEnum {
        case .data:
            await handleDataFrame(data, sequenceNumber: sequenceNumber, sessionId: sessionId, streamId: streamId, connection: connection)
        case .ack:
            print("Received ACK for sequence \(sequenceNumber)")
        case .nak:
            print("Received NAK for sequence \(sequenceNumber)")
        case .heartbeat:
            print("Received heartbeat from session \(sessionId)")
        case .flowControl:
            print("Received flow control from session \(sessionId)")
        }
    }
    
    private func handleDataFrame(_ data: Data, sequenceNumber: UInt32, sessionId: UInt32, streamId: UInt32, connection: NWConnection) async {
        let headerLength = 32
        
        // 发送ACK
        do {
            let ackFrame = try createAckFrame(sequenceNumber: sequenceNumber, sessionId: sessionId, streamId: streamId)
            connection.send(content: ackFrame, completion: .idempotent)
        } catch {
            print("Failed to send ACK: \(error)")
        }
        
        // 检查重复
        if receivedSequences.contains(sequenceNumber) {
            print("Duplicate message \(sequenceNumber), ignoring")
            return
        }
        
        receivedSequences.insert(sequenceNumber)
        
        // 提取数据
        if data.count > headerLength {
            let payload = data.subdata(in: headerLength..<data.count)
            
            if sequenceNumber == expectedSequence {
                // 按序到达
                onDataReceived?(payload, sequenceNumber, sessionId, streamId)
                expectedSequence += 1
                
                // 检查缓存的乱序消息
                await processBufferedMessages()
            } else if sequenceNumber > expectedSequence {
                // 乱序到达，缓存
                outOfOrderBuffer[sequenceNumber] = payload
                print("Out of order message \(sequenceNumber), expected \(expectedSequence)")
            } else {
                // 过期消息，忽略
                print("Late message \(sequenceNumber), expected \(expectedSequence)")
            }
        }
    }
    
    private func processBufferedMessages() async {
        while let data = outOfOrderBuffer.removeValue(forKey: expectedSequence) {
            onDataReceived?(data, expectedSequence, 1, 1001) // 使用默认值
            expectedSequence += 1
        }
    }
    
    private func createAckFrame(sequenceNumber: UInt32, sessionId: UInt32, streamId: UInt32) throws -> Data {
        var frame = Data()
        let headerLength = 32
        
        let frameLength = headerLength
        let frameType = ReliableAeronClient.FrameType.ack.rawValue
        let flags: UInt8 = 0x00
        let version: UInt8 = 0x01
        let termId: UInt32 = 0
        let termOffset: UInt32 = 0
        
        frame.append(withUnsafeBytes(of: UInt32(frameLength).littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: frameType.littleEndian) { Data($0) })
        frame.append(flags)
        frame.append(version)
        frame.append(withUnsafeBytes(of: sessionId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: streamId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: termId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: termOffset.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: sequenceNumber.littleEndian) { Data($0) })
        
        let paddingNeeded = headerLength - frame.count
        if paddingNeeded > 0 {
            frame.append(Data(repeating: 0, count: paddingNeeded))
        }
        
        return frame
    }
    
    public func getStatistics() -> ReceiverStatistics {
        return ReceiverStatistics(
            expectedSequence: expectedSequence,
            receivedCount: receivedSequences.count,
            bufferedCount: outOfOrderBuffer.count,
            isListening: isListening
        )
    }
}

// MARK: - 统计信息结构

public struct ReliabilityStatistics {
    public let pendingMessages: Int
    public let sequenceNumber: UInt32
    public let receivedSequences: Int
    public let isConnected: Bool
    
    public func printStatistics() {
        print("=== Reliability Statistics ===")
        print("Pending messages: \(pendingMessages)")
        print("Next sequence: \(sequenceNumber)")
        print("Received sequences: \(receivedSequences)")
        print("Connected: \(isConnected)")
    }
}

public struct ReceiverStatistics {
    public let expectedSequence: UInt32
    public let receivedCount: Int
    public let bufferedCount: Int
    public let isListening: Bool
    
    public func printStatistics() {
        print("=== Receiver Statistics ===")
        print("Expected sequence: \(expectedSequence)")
        print("Received count: \(receivedCount)")
        print("Buffered messages: \(bufferedCount)")
        print("Listening: \(isListening)")
    }
}