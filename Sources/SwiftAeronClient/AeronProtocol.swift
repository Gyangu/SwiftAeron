import Foundation
import Network

/// Aeron协议的Swift实现子集
public class SwiftAeronClient {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var isConnected = false
    
    // Aeron协议常量
    private let AERON_HEADER_LENGTH: Int = 32
    private let DATA_HEADER_LENGTH: Int = 32
    private let FRAME_ALIGNMENT: Int = 32
    
    public init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        // 使用UDP连接
        connection = NWConnection(to: endpoint, using: .udp)
        queue = DispatchQueue(label: "swift-aeron-client")
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
                    continuation.resume(throwing: AeronError.connectionCancelled)
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
    
    public func sendData(_ data: Data, sessionId: UInt32 = 1, streamId: UInt32 = 1001) async throws {
        guard isConnected else {
            throw AeronError.notConnected
        }
        
        // 创建Aeron数据帧
        let frame = try createDataFrame(data: data, sessionId: sessionId, streamId: streamId)
        
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
    
    public func disconnect() {
        connection.cancel()
        isConnected = false
    }
    
    // MARK: - Aeron协议实现
    
    private func createDataFrame(data: Data, sessionId: UInt32, streamId: UInt32) throws -> Data {
        var frame = Data()
        
        // Aeron数据帧头部
        let frameLength = DATA_HEADER_LENGTH + data.count
        let frameType: UInt16 = 0x01  // DATA frame type
        let flags: UInt8 = 0x80       // Begin and End flags
        let version: UInt8 = 0x01
        let termId: UInt32 = 0
        let termOffset: UInt32 = 0
        
        // 构建帧头 (32字节)
        frame.append(withUnsafeBytes(of: UInt32(frameLength).littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: frameType.littleEndian) { Data($0) })
        frame.append(flags)
        frame.append(version)
        frame.append(withUnsafeBytes(of: sessionId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: streamId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: termId.littleEndian) { Data($0) })
        frame.append(withUnsafeBytes(of: termOffset.littleEndian) { Data($0) })
        
        // 填充到32字节对齐
        let paddingNeeded = DATA_HEADER_LENGTH - frame.count
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
}

// MARK: - 接收端实现

public class SwiftAeronReceiver {
    private let listener: NWListener
    private let queue: DispatchQueue
    private var isListening = false
    public var onDataReceived: ((Data, UInt32, UInt32) -> Void)?
    
    public init(port: UInt16) throws {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        queue = DispatchQueue(label: "swift-aeron-receiver")
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
                self.processAeronFrame(data)
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
    
    private func processAeronFrame(_ data: Data) {
        let headerLength = 32
        
        guard data.count >= headerLength else {
            print("Frame too short: \(data.count)")
            return
        }
        
        // 解析Aeron帧头
        let frameLength = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let frameType = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }.littleEndian
        let sessionId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }.littleEndian
        let streamId = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }.littleEndian
        
        print("Received Aeron frame: length=\(frameLength), type=\(frameType), session=\(sessionId), stream=\(streamId)")
        
        // 提取数据部分
        if data.count > headerLength {
            let payload = data.subdata(in: headerLength..<data.count)
            onDataReceived?(payload, sessionId, streamId)
        }
    }
}

// MARK: - 错误定义

public enum AeronError: Error {
    case notConnected
    case connectionCancelled
    case invalidFrame
    case frameTooShort
    
    public var localizedDescription: String {
        switch self {
        case .notConnected:
            return "Not connected to Aeron endpoint"
        case .connectionCancelled:
            return "Connection was cancelled"
        case .invalidFrame:
            return "Invalid Aeron frame"
        case .frameTooShort:
            return "Frame too short"
        }
    }
}

// MARK: - 性能测试工具

public class AeronPerformanceTest {
    private let client: SwiftAeronClient
    private let messageSize: Int
    private let messageCount: Int
    
    public init(host: String, port: UInt16, messageSize: Int, messageCount: Int) {
        self.client = SwiftAeronClient(host: host, port: port)
        self.messageSize = messageSize
        self.messageCount = messageCount
    }
    
    public func runTest() async throws -> PerformanceResult {
        try await client.connect()
        
        let testData = Data(repeating: 0, count: messageSize)
        let startTime = Date()
        
        for i in 0..<messageCount {
            try await client.sendData(testData)
            
            if i % 100 == 0 {
                print("Sent \(i + 1) messages")
            }
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        let totalBytes = messageSize * messageCount
        let throughputMBps = Double(totalBytes) / 1024.0 / 1024.0 / duration
        let messagesPerSecond = Double(messageCount) / duration
        
        client.disconnect()
        
        return PerformanceResult(
            duration: duration,
            totalBytes: totalBytes,
            throughputMBps: throughputMBps,
            messagesPerSecond: messagesPerSecond,
            messageCount: messageCount
        )
    }
}

public struct PerformanceResult {
    public let duration: TimeInterval
    public let totalBytes: Int
    public let throughputMBps: Double
    public let messagesPerSecond: Double
    public let messageCount: Int
    
    public func printResults() {
        print("\n=== Swift Aeron Performance Results ===")
        print("Total messages: \(messageCount)")
        print("Total bytes: \(totalBytes) (\(String(format: "%.2f", Double(totalBytes) / 1024.0 / 1024.0)) MB)")
        print("Duration: \(String(format: "%.2f", duration))s")
        print("Throughput: \(String(format: "%.2f", throughputMBps)) MB/s")
        print("Messages/sec: \(String(format: "%.2f", messagesPerSecond))")
    }
}