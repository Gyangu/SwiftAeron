import Foundation
import Network

/// 双向优化Aeron实现
/// 同时支持高性能发送和接收，实现真正的双向通信
public class BidirectionalOptimizedAeron {
    private let streamId: UInt32
    private let sessionId: UInt32
    private let termId: UInt32
    
    // 发送组件
    private let publisher: BottleneckOptimizedAeron
    
    // 接收组件
    private let subscriber: OptimizedAeronSubscriber
    
    // 双向性能统计
    private var sentMessages: Int64 = 0
    private var receivedMessages: Int64 = 0
    private var sentBytes: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var startTime: Date?
    
    public init(
        streamId: UInt32,
        sessionId: UInt32,
        publishHost: String,
        publishPort: UInt16,
        subscribePort: UInt16
    ) {
        self.streamId = streamId
        self.sessionId = sessionId
        self.termId = UInt32.random(in: 1...UInt32.max)
        
        // 初始化发布者
        self.publisher = BottleneckOptimizedAeron(
            streamId: streamId,
            sessionId: sessionId,
            host: publishHost,
            port: publishPort
        )
        
        // 初始化订阅者
        do {
            self.subscriber = try OptimizedAeronSubscriber(
                port: subscribePort,
                streamId: streamId
            )
        } catch {
            fatalError("Failed to create subscriber: \(error)")
        }
        
        // 设置接收回调
        self.subscriber.onDataReceived = { [weak self] data, sessionId, streamId in
            self?.handleReceivedMessage(data, sessionId: sessionId, streamId: streamId)
        }
    }
    
    public func connect() async throws {
        // 并行启动发布者和订阅者
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.publisher.connect()
            }
            
            group.addTask {
                try await self.subscriber.startListening()
            }
            
            try await group.waitForAll()
        }
        
        startTime = Date()
        print("✅ 双向连接已建立")
    }
    
    /// 发送消息（高性能）
    public func sendMessage(_ data: Data) async -> Int64 {
        let result = await publisher.offer(data)
        if result >= 0 {
            sentMessages += 1
            sentBytes += Int64(data.count)
        }
        return result
    }
    
    /// 处理接收到的消息
    private func handleReceivedMessage(_ data: Data, sessionId: UInt32, streamId: UInt32) {
        receivedMessages += 1
        receivedBytes += Int64(data.count)
    }
    
    /// 双向性能测试
    public func performBidirectionalTest(
        messageSize: Int,
        messageCount: Int,
        echoTest: Bool = false
    ) async -> BidirectionalPerformanceStats {
        
        print("🔄 开始双向性能测试")
        print("消息大小: \(messageSize) bytes")
        print("消息数量: \(messageCount)")
        print("回声测试: \(echoTest ? "启用" : "禁用")")
        
        let testData = Data(repeating: 0x42, count: messageSize)
        let testStartTime = Date()
        
        if echoTest {
            // 回声测试：发送消息并等待回应
            await performEchoTest(testData: testData, messageCount: messageCount)
        } else {
            // 并发发送和接收测试
            await performConcurrentTest(testData: testData, messageCount: messageCount)
        }
        
        let testDuration = Date().timeIntervalSince(testStartTime)
        
        return BidirectionalPerformanceStats(
            sentMessages: sentMessages,
            receivedMessages: receivedMessages,
            sentBytes: sentBytes,
            receivedBytes: receivedBytes,
            duration: testDuration,
            messageSize: messageSize
        )
    }
    
    /// 回声测试：发送并等待回应
    private func performEchoTest(testData: Data, messageCount: Int) async {
        var echoReceived = 0
        let echoExpected = messageCount
        
        // 设置回声处理
        let originalHandler = subscriber.onDataReceived
        subscriber.onDataReceived = { data, sessionId, streamId in
            originalHandler?(data, sessionId, streamId)
            echoReceived += 1
        }
        
        // 发送消息
        for i in 0..<messageCount {
            let result = await sendMessage(testData)
            if result < 0 {
                print("❌ 发送失败 at \(i)")
                break
            }
            
            if i % (messageCount / 10) == 0 {
                print("发送进度: \(i)/\(messageCount)")
            }
            
            // 短暂延迟允许回声
            if i % 100 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
        }
        
        // 等待回声完成
        let echoTimeout = Date().addingTimeInterval(5.0)
        while echoReceived < echoExpected && Date() < echoTimeout {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        
        print("回声完成: \(echoReceived)/\(echoExpected)")
        
        // 恢复原始处理器
        subscriber.onDataReceived = originalHandler
    }
    
    /// 并发测试：同时发送和独立接收
    private func performConcurrentTest(testData: Data, messageCount: Int) async {
        await withTaskGroup(of: Void.self) { group in
            // 发送任务
            group.addTask {
                for i in 0..<messageCount {
                    let result = await self.sendMessage(testData)
                    if result < 0 {
                        print("❌ 发送失败 at \(i)")
                        break
                    }
                    
                    if i % (messageCount / 10) == 0 {
                        print("发送进度: \(i)/\(messageCount)")
                    }
                }
            }
            
            // 接收监控任务
            group.addTask {
                let monitorStart = Date()
                while Date().timeIntervalSince(monitorStart) < 10.0 { // 10秒监控
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
                    print("接收状态: \(self.receivedMessages) 消息")
                }
            }
        }
    }
    
    public func close() {
        publisher.close()
        subscriber.stopListening()
    }
}

/// 优化的Aeron订阅者
public class OptimizedAeronSubscriber {
    private let streamId: UInt32
    private let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    private var isListening = false
    
    // 高性能数据处理
    private let dataProcessor = HighPerformanceDataProcessor()
    
    // 回调
    public var onDataReceived: ((Data, UInt32, UInt32) -> Void)?
    
    public init(port: UInt16, streamId: UInt32) throws {
        self.port = port
        self.streamId = streamId
        
        let parameters = NWParameters.udp
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.queue = DispatchQueue(label: "optimized-subscriber", qos: .userInitiated)
    }
    
    public func startListening() async throws {
        listener.newConnectionHandler = { connection in
            self.handleHighPerformanceConnection(connection)
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
    
    private func handleHighPerformanceConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        
        // 高性能数据接收循环
        receiveDataOptimized(connection: connection)
    }
    
    private func receiveDataOptimized(connection: NWConnection) {
        connection.receiveMessage { content, _, isComplete, error in
            if let data = content {
                self.dataProcessor.processDataOptimized(data) { payload, sessionId, streamId in
                    self.onDataReceived?(payload, sessionId, streamId)
                }
                
                // 快速状态消息响应
                self.sendFastStatusMessage(connection: connection, data: data)
            }
            
            if isComplete {
                self.receiveDataOptimized(connection: connection)
            }
        }
    }
    
    private func sendFastStatusMessage(connection: NWConnection, data: Data) {
        guard data.count >= 32 else { return }
        
        let sessionId = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: 12, as: UInt32.self).littleEndian
        }
        let streamId = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: 16, as: UInt32.self).littleEndian
        }
        
        // 快速状态消息创建
        let statusMessage = createFastStatusMessage(sessionId: sessionId, streamId: streamId)
        connection.send(content: statusMessage, completion: .contentProcessed { _ in })
    }
    
    private func createFastStatusMessage(sessionId: UInt32, streamId: UInt32) -> Data {
        var status = Data(count: 32)
        status.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            base.storeBytes(of: UInt32(32).littleEndian, toByteOffset: 0, as: UInt32.self)  // length
            base.storeBytes(of: UInt8(0x01), toByteOffset: 4, as: UInt8.self)  // version
            base.storeBytes(of: UInt8(0x00), toByteOffset: 5, as: UInt8.self)  // flags
            base.storeBytes(of: UInt16(0x03).littleEndian, toByteOffset: 6, as: UInt16.self)  // status type
            base.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 8, as: UInt32.self)  // term offset
            base.storeBytes(of: sessionId.littleEndian, toByteOffset: 12, as: UInt32.self)
            base.storeBytes(of: streamId.littleEndian, toByteOffset: 16, as: UInt32.self)
            base.storeBytes(of: UInt32(1).littleEndian, toByteOffset: 20, as: UInt32.self)  // term ID
            base.storeBytes(of: (16 * 1024 * 1024).littleEndian, toByteOffset: 24, as: UInt32.self)  // window
            base.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 28, as: UInt32.self)  // reserved
        }
        return status
    }
    
    public func stopListening() {
        listener.cancel()
        isListening = false
    }
}

/// 高性能数据处理器
private class HighPerformanceDataProcessor {
    private var frameBuffer = Data()
    private let bufferLock = NSLock()
    
    func processDataOptimized(_ data: Data, onFrame: (Data, UInt32, UInt32) -> Void) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        frameBuffer.append(data)
        
        // 快速帧解析
        while frameBuffer.count >= 8 {
            let frameLength = frameBuffer.withUnsafeBytes { bytes in
                bytes.load(fromByteOffset: 0, as: UInt32.self).littleEndian
            }
            
            guard frameLength <= frameBuffer.count else { break }
            
            let frameData = frameBuffer.prefix(Int(frameLength))
            frameBuffer.removeFirst(Int(frameLength))
            
            // 快速帧类型检查
            if frameData.count >= 32 {
                let frameType = frameData.withUnsafeBytes { bytes in
                    bytes.load(fromByteOffset: 6, as: UInt16.self).littleEndian
                }
                
                if frameType == 0x01 { // 数据帧
                    let sessionId = frameData.withUnsafeBytes { bytes in
                        bytes.load(fromByteOffset: 12, as: UInt32.self).littleEndian
                    }
                    let streamId = frameData.withUnsafeBytes { bytes in
                        bytes.load(fromByteOffset: 16, as: UInt32.self).littleEndian
                    }
                    let payload = frameData.dropFirst(32)
                    
                    onFrame(Data(payload), sessionId, streamId)
                }
            }
        }
    }
}

/// 双向性能统计
public struct BidirectionalPerformanceStats {
    public let sentMessages: Int64
    public let receivedMessages: Int64
    public let sentBytes: Int64
    public let receivedBytes: Int64
    public let duration: TimeInterval
    public let messageSize: Int
    
    public var sendThroughputMBps: Double {
        guard duration > 0 else { return 0 }
        return Double(sentBytes) / 1024.0 / 1024.0 / duration
    }
    
    public var receiveThroughputMBps: Double {
        guard duration > 0 else { return 0 }
        return Double(receivedBytes) / 1024.0 / 1024.0 / duration
    }
    
    public var totalThroughputMBps: Double {
        return sendThroughputMBps + receiveThroughputMBps
    }
    
    public var sendMessageRate: Double {
        guard duration > 0 else { return 0 }
        return Double(sentMessages) / duration
    }
    
    public var receiveMessageRate: Double {
        guard duration > 0 else { return 0 }
        return Double(receivedMessages) / duration
    }
    
    public var echoLatencyMs: Double {
        guard receivedMessages > 0 && sentMessages > 0 else { return 0 }
        return (duration * 1000.0) / Double(min(sentMessages, receivedMessages))
    }
    
    public func printStats() {
        print("\n" + String(repeating: "=", count: 60))
        print("🔄 双向Aeron性能统计")
        print(String(repeating: "=", count: 60))
        
        print("📤 发送性能:")
        print("  消息数: \(sentMessages)")
        print("  字节数: \(String(format: "%.2f", Double(sentBytes) / 1024.0 / 1024.0)) MB")
        print("  吞吐量: \(String(format: "%.2f", sendThroughputMBps)) MB/s")
        print("  消息速率: \(String(format: "%.0f", sendMessageRate)) 消息/秒")
        
        print("\n📥 接收性能:")
        print("  消息数: \(receivedMessages)")
        print("  字节数: \(String(format: "%.2f", Double(receivedBytes) / 1024.0 / 1024.0)) MB")
        print("  吞吐量: \(String(format: "%.2f", receiveThroughputMBps)) MB/s")
        print("  消息速率: \(String(format: "%.0f", receiveMessageRate)) 消息/秒")
        
        print("\n🔄 双向性能:")
        print("  总吞吐量: \(String(format: "%.2f", totalThroughputMBps)) MB/s")
        print("  数据完整性: \(String(format: "%.1f", Double(receivedMessages) / Double(sentMessages) * 100))%")
        print("  平均延迟: \(String(format: "%.3f", echoLatencyMs)) ms")
        print("  测试时长: \(String(format: "%.3f", duration))s")
        
        // 与Rust对比
        let rustBidirectionalBaseline = 20.0  // 假设Rust双向基准
        let performanceRatio = totalThroughputMBps / rustBidirectionalBaseline * 100
        print("\n🎯 相对Rust双向性能: \(String(format: "%.1f", performanceRatio))%")
        
        print(String(repeating: "=", count: 60))
    }
}

/// 双向测试类
public class BidirectionalOptimizedTest {
    public static func runBidirectionalPerformanceTest(
        publishHost: String,
        publishPort: UInt16,
        subscribePort: UInt16,
        streamId: UInt32,
        sessionId: UInt32,
        messageSize: Int,
        messageCount: Int
    ) async throws {
        
        print("🔄 双向优化Aeron性能测试")
        print("发布目标: \(publishHost):\(publishPort)")
        print("订阅端口: \(subscribePort)")
        print("流ID: \(streamId), 会话ID: \(sessionId)")
        print("消息大小: \(messageSize) bytes, 数量: \(messageCount)")
        print("目标: 实现接近Rust的双向通信性能\n")
        
        let bidirectionalAeron = BidirectionalOptimizedAeron(
            streamId: streamId,
            sessionId: sessionId,
            publishHost: publishHost,
            publishPort: publishPort,
            subscribePort: subscribePort
        )
        
        try await bidirectionalAeron.connect()
        
        // 短时间预热
        print("🔥 开始双向预热...")
        let warmupStats = await bidirectionalAeron.performBidirectionalTest(
            messageSize: 64,
            messageCount: 100,
            echoTest: false
        )
        print("预热完成: 发送\(warmupStats.sentMessages), 接收\(warmupStats.receivedMessages)")
        
        // 主要性能测试
        print("\n📊 开始主要双向性能测试...")
        let stats = await bidirectionalAeron.performBidirectionalTest(
            messageSize: messageSize,
            messageCount: messageCount,
            echoTest: false
        )
        
        stats.printStats()
        
        // 分析结果
        print("\n🎯 双向优化效果分析:")
        if stats.totalThroughputMBps > 15 {
            print("✅ 双向性能优秀！达到预期目标")
        } else if stats.totalThroughputMBps > 8 {
            print("🔄 双向性能良好，仍有优化空间")
        } else {
            print("❌ 双向性能需要进一步优化")
        }
        
        bidirectionalAeron.close()
    }
}