import Foundation
import Network

/// 简化的IPC传输层 - 专注于客户端连接
public class SimpleIPCTransport {
    private let socketPath: String
    private var connection: NWConnection?
    private let queue: DispatchQueue
    
    public init(socketPath: String) {
        self.socketPath = socketPath
        self.queue = DispatchQueue(label: "simple-ipc", qos: .userInitiated)
    }
    
    public func connect() async throws {
        print("🔗 连接到Unix socket: \\(socketPath)")
        
        let endpoint = NWEndpoint.unix(path: socketPath)
        connection = NWConnection(to: endpoint, using: .tcp)
        
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            
            connection?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !hasResumed {
                        hasResumed = true
                        print("✅ IPC连接成功")
                        continuation.resume()
                    }
                case .failed(let error):
                    if !hasResumed {
                        hasResumed = true
                        print("❌ IPC连接失败: \\(error)")
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
            
            connection?.start(queue: queue)
        }
    }
    
    public func sendData(_ data: Data) throws {
        guard let connection = connection else {
            throw AeronError.notConnected
        }
        
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil {
                print("发送错误: \\(String(describing: error))")
            }
        })
    }
    
    public func close() {
        connection?.cancel()
    }
}

/// 简化的IPC Aeron Publication
public class SimpleIPCPublication {
    private let transport: SimpleIPCTransport
    private let streamId: UInt32
    private let sessionId: UInt32
    private let termId: UInt32
    private var termOffset: UInt32 = 0
    
    // 性能统计
    private var messagesSent: Int64 = 0
    private var bytesSent: Int64 = 0
    private var startTime: Date?
    
    public init(socketPath: String, streamId: UInt32, sessionId: UInt32) {
        self.streamId = streamId
        self.sessionId = sessionId
        self.termId = UInt32.random(in: 1...UInt32.max)
        self.transport = SimpleIPCTransport(socketPath: socketPath)
    }
    
    public func connect() async throws {
        try await transport.connect()
        
        // 发送Setup帧
        let setupFrame = createSetupFrame()
        print("📤 发送Setup帧 (\\(setupFrame.count) bytes)")
        try transport.sendData(setupFrame)
        
        startTime = Date()
        print("✅ IPC Aeron连接已建立")
    }
    
    public func offer(_ data: Data) async -> Int64 {
        let dataFrame = createDataFrame(payload: data)
        
        do {
            try transport.sendData(dataFrame)
            
            messagesSent += 1
            bytesSent += Int64(data.count)
            termOffset += UInt32(dataFrame.count)
            
            return Int64(termOffset)
        } catch {
            print("发送失败: \\(error)")
            return -1
        }
    }
    
    private func createSetupFrame() -> Data {
        var frame = Data(count: 40)
        frame.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            base.storeBytes(of: UInt32(40).littleEndian, toByteOffset: 0, as: UInt32.self)  // length
            base.storeBytes(of: UInt8(0x01), toByteOffset: 4, as: UInt8.self)  // version
            base.storeBytes(of: UInt8(0x00), toByteOffset: 5, as: UInt8.self)  // flags
            base.storeBytes(of: UInt16(0x05).littleEndian, toByteOffset: 6, as: UInt16.self)  // setup type
            base.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 8, as: UInt32.self)  // term offset
            base.storeBytes(of: sessionId.littleEndian, toByteOffset: 12, as: UInt32.self)
            base.storeBytes(of: streamId.littleEndian, toByteOffset: 16, as: UInt32.self)
            base.storeBytes(of: termId.littleEndian, toByteOffset: 20, as: UInt32.self)
        }
        return frame
    }
    
    private func createDataFrame(payload: Data) -> Data {
        let frameLength = 32 + payload.count
        var frame = Data(count: frameLength)
        
        frame.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            base.storeBytes(of: UInt32(frameLength).littleEndian, toByteOffset: 0, as: UInt32.self)
            base.storeBytes(of: UInt8(0x01), toByteOffset: 4, as: UInt8.self)  // version
            base.storeBytes(of: UInt8(0x00), toByteOffset: 5, as: UInt8.self)  // flags
            base.storeBytes(of: UInt16(0x01).littleEndian, toByteOffset: 6, as: UInt16.self)  // data type
            base.storeBytes(of: termOffset.littleEndian, toByteOffset: 8, as: UInt32.self)
            base.storeBytes(of: sessionId.littleEndian, toByteOffset: 12, as: UInt32.self)
            base.storeBytes(of: streamId.littleEndian, toByteOffset: 16, as: UInt32.self)
            base.storeBytes(of: termId.littleEndian, toByteOffset: 20, as: UInt32.self)
        }
        
        // 添加payload
        frame.replaceSubrange(32..<frameLength, with: payload)
        return frame
    }
    
    public func getPerformanceStats() -> IPCPerformanceStats {
        let duration = startTime?.timeIntervalSinceNow ?? 0
        return IPCPerformanceStats(
            messagesSent: messagesSent,
            bytesSent: bytesSent,
            duration: abs(duration)
        )
    }
    
    public func close() {
        transport.close()
    }
}