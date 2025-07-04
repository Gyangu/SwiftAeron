import Foundation
import SwiftAeronClient

/// 真正的Aeron性能测试 - 按照Aeron设计规范
public struct AeronPerformanceTest {
    private let host: String
    private let port: UInt16
    private let messageSize: Int
    private let messageCount: Int
    private let streamId: Int32
    private let sessionId: Int32
    
    public init(host: String, port: UInt16, messageSize: Int, messageCount: Int, streamId: Int32 = 1001, sessionId: Int32 = 1) {
        self.host = host
        self.port = port
        self.messageSize = messageSize
        self.messageCount = messageCount
        self.streamId = streamId
        self.sessionId = sessionId
    }
    
    /// 高性能发布测试 - 使用Aeron Publication
    public func runPublisherTest() async throws -> AeronTestResult {
        print("🚀 启动Aeron高性能发布测试")
        print("- 目标: \(host):\(port)")
        print("- 流ID: \(streamId), 会话ID: \(sessionId)")
        print("- 消息大小: \(messageSize) bytes")
        print("- 消息数量: \(messageCount)")
        print("- 术语缓冲区: \(AeronLogBufferDescriptor.MIN_TERM_LENGTH / 1024)KB")
        print("")
        
        // 创建Aeron发布者
        let publication = AeronPublication(
            streamId: streamId,
            sessionId: sessionId,
            initialTermId: 0,
            termBufferLength: AeronLogBufferDescriptor.MIN_TERM_LENGTH,
            host: host,
            port: port
        )
        
        try await publication.connect()
        print("✅ Aeron发布者已连接")
        
        // 准备测试数据
        let testData = createTestData(size: messageSize)
        
        // 性能测试 - 批量发布
        let startTime = Date()
        var successCount = 0
        var backPressureCount = 0
        var totalBytes = 0
        
        print("📤 开始批量发布...")
        
        var i = 0
        while i < messageCount {
            let result = await publication.offer(testData)
            
            if result > 0 {
                successCount += 1
                totalBytes += messageSize
                i += 1
            } else if result == AeronPublication.BACK_PRESSURED {
                backPressureCount += 1
                // 遇到背压时短暂等待
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
                // 不增加i，重试当前消息
            } else {
                print("❌ 发布失败: \(result)")
                break
            }
            
            // 进度报告
            if i % (messageCount / 10) == 0 && i > 0 {
                let progress = Double(i) / Double(messageCount) * 100
                print("进度: \(String(format: "%.1f", progress))% (\(i)/\(messageCount))")
            }
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        publication.close()
        
        return AeronTestResult(
            testType: "Aeron发布者",
            messageCount: successCount,
            totalBytes: totalBytes,
            duration: duration,
            backPressureEvents: backPressureCount,
            position: publication.getPosition()
        )
    }
    
    /// 零拷贝发布测试 - 使用tryClaim
    public func runZeroCopyTest() async throws -> AeronTestResult {
        print("🚀 启动Aeron零拷贝性能测试")
        print("")
        
        let publication = AeronPublication(
            streamId: streamId,
            sessionId: sessionId,
            initialTermId: 0,
            termBufferLength: AeronLogBufferDescriptor.MIN_TERM_LENGTH,
            host: host,
            port: port
        )
        
        try await publication.connect()
        print("✅ Aeron发布者已连接（零拷贝模式）")
        
        let startTime = Date()
        var successCount = 0
        var claimFailures = 0
        var totalBytes = 0
        
        print("📤 开始零拷贝发布...")
        
        // 准备测试数据模式
        let testPattern = Data([0xAA, 0xBB, 0xCC, 0xDD])
        
        var i = 0
        while i < messageCount {
            if let claim = await publication.tryClaim(length: messageSize) {
                // 直接写入到术语缓冲区
                for j in stride(from: 0, to: messageSize, by: testPattern.count) {
                    let remainingBytes = min(testPattern.count, messageSize - j)
                    claim.putBytes(testPattern.prefix(remainingBytes), offset: j)
                }
                
                // 写入消息序号
                claim.putInt32(Int32(i), offset: messageSize - 4)
                
                // 提交
                claim.commit()
                
                successCount += 1
                totalBytes += messageSize
                i += 1
            } else {
                claimFailures += 1
                // 短暂等待后重试
                try await Task.sleep(nanoseconds: 100_000) // 0.1ms
                // 不增加i，重试当前消息
            }
            
            if i % (messageCount / 10) == 0 && i > 0 {
                let progress = Double(i) / Double(messageCount) * 100
                print("零拷贝进度: \(String(format: "%.1f", progress))%")
            }
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        publication.close()
        
        return AeronTestResult(
            testType: "Aeron零拷贝发布",
            messageCount: successCount,
            totalBytes: totalBytes,
            duration: duration,
            backPressureEvents: claimFailures,
            position: publication.getPosition()
        )
    }
    
    /// 订阅接收测试
    public func runSubscriberTest(expectedMessages: Int, timeoutSeconds: Int = 60) async throws -> AeronTestResult {
        print("🎯 启动Aeron订阅接收测试")
        print("- 监听端口: \(port)")
        print("- 流ID: \(streamId)")
        print("- 期望消息: \(expectedMessages)")
        print("")
        
        let subscription = try AeronSubscription(streamId: streamId, port: port)
        
        var receivedCount = 0
        var totalBytes = 0
        var firstMessageTime: Date?
        var lastMessageTime: Date?
        var fragmentsProcessed = 0
        var duplicateCount = 0
        var outOfOrderCount = 0
        var lastSequence: Int32 = -1
        
        // 设置片段处理器
        subscription.fragmentHandler = { data, sessionId, streamId, position in
            if firstMessageTime == nil {
                firstMessageTime = Date()
                print("📨 收到第一条消息")
            }
            
            lastMessageTime = Date()
            receivedCount += 1
            totalBytes += data.count
            fragmentsProcessed += 1
            
            // 验证消息序号（如果有）
            if data.count >= 4 {
                let sequence = data.withUnsafeBytes { $0.load(fromByteOffset: data.count - 4, as: Int32.self) }.littleEndian
                
                if sequence <= lastSequence {
                    duplicateCount += 1
                } else if sequence != lastSequence + 1 && lastSequence >= 0 {
                    outOfOrderCount += 1
                }
                lastSequence = sequence
            }
            
            if receivedCount % (expectedMessages / 10) == 0 {
                print("已接收: \(receivedCount) 消息, 位置: \(position)")
            }
        }
        
        // 设置图像处理器
        subscription.availableImageHandler = { image in
            print("🖼️ 新图像可用: 会话\(image.sessionId), 流\(image.streamId)")
        }
        
        subscription.unavailableImageHandler = { image in
            print("❌ 图像不可用: 会话\(image.sessionId)")
        }
        
        try await subscription.startListening()
        print("✅ Aeron订阅者开始监听")
        
        let startTime = Date()
        var elapsedTime = 0
        
        // 主轮询循环
        while receivedCount < expectedMessages && elapsedTime < timeoutSeconds {
            let polledFragments = await subscription.poll(limit: 100)
            
            if polledFragments == 0 {
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
            
            elapsedTime = Int(Date().timeIntervalSince(startTime))
            
            if elapsedTime % 10 == 0 && elapsedTime > 0 {
                print("⏱️ 已等待 \(elapsedTime)s, 接收 \(receivedCount)/\(expectedMessages)")
            }
        }
        
        subscription.stopListening()
        
        let duration = firstMessageTime.map { Date().timeIntervalSince($0) } ?? 0
        
        return AeronTestResult(
            testType: "Aeron订阅者",
            messageCount: receivedCount,
            totalBytes: totalBytes,
            duration: duration,
            backPressureEvents: 0,
            position: 0,
            fragmentsProcessed: fragmentsProcessed,
            duplicateCount: duplicateCount,
            outOfOrderCount: outOfOrderCount
        )
    }
    
    private func createTestData(size: Int) -> Data {
        var data = Data(capacity: size)
        
        // 创建可识别的测试模式
        let pattern: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        
        for i in 0..<size {
            data.append(pattern[i % pattern.count])
        }
        
        return data
    }
}

/// Aeron测试结果
public struct AeronTestResult {
    public let testType: String
    public let messageCount: Int
    public let totalBytes: Int
    public let duration: TimeInterval
    public let backPressureEvents: Int
    public let position: Int64
    public let fragmentsProcessed: Int
    public let duplicateCount: Int
    public let outOfOrderCount: Int
    
    public init(testType: String, messageCount: Int, totalBytes: Int, duration: TimeInterval, backPressureEvents: Int, position: Int64, fragmentsProcessed: Int = 0, duplicateCount: Int = 0, outOfOrderCount: Int = 0) {
        self.testType = testType
        self.messageCount = messageCount
        self.totalBytes = totalBytes
        self.duration = duration
        self.backPressureEvents = backPressureEvents
        self.position = position
        self.fragmentsProcessed = fragmentsProcessed
        self.duplicateCount = duplicateCount
        self.outOfOrderCount = outOfOrderCount
    }
    
    public func printResults() {
        print("")
        print("=================== \(testType) 测试结果 ===================")
        print("📊 性能指标:")
        print("- 消息数量: \(messageCount)")
        print("- 总字节数: \(String(format: "%.2f", Double(totalBytes) / 1024.0 / 1024.0)) MB")
        print("- 测试时长: \(String(format: "%.3f", duration))s")
        
        if duration > 0 {
            let throughputMBps = Double(totalBytes) / 1024.0 / 1024.0 / duration
            let messagesPerSecond = Double(messageCount) / duration
            
            print("- 吞吐量: \(String(format: "%.2f", throughputMBps)) MB/s")
            print("- 消息速率: \(String(format: "%.0f", messagesPerSecond)) 消息/秒")
        }
        
        print("")
        print("🔧 系统指标:")
        print("- 背压事件: \(backPressureEvents)")
        print("- 最终位置: \(position)")
        
        if fragmentsProcessed > 0 {
            print("- 处理片段: \(fragmentsProcessed)")
        }
        
        if duplicateCount > 0 || outOfOrderCount > 0 {
            print("📈 可靠性指标:")
            print("- 重复消息: \(duplicateCount)")
            print("- 乱序消息: \(outOfOrderCount)")
            let reliability = Double(messageCount - duplicateCount - outOfOrderCount) / Double(messageCount) * 100
            print("- 可靠性: \(String(format: "%.1f", reliability))%")
        }
        
        print("=" + String(repeating: "=", count: testType.count + 16))
        print("")
    }
}

/// Aeron双向性能测试
public struct AeronBidirectionalTest {
    public static func runBidirectionalPerformanceTest(
        publishHost: String,
        publishPort: UInt16,
        subscribePort: UInt16,
        messageSize: Int,
        messageCount: Int
    ) async throws {
        
        print("🔄 Aeron双向高性能测试")
        print("发布目标: \(publishHost):\(publishPort)")
        print("订阅端口: \(subscribePort)")
        print("消息大小: \(messageSize) bytes")
        print("消息数量: \(messageCount)")
        print("")
        
        // 测试1: 发布性能
        let publishTest = AeronPerformanceTest(
            host: publishHost,
            port: publishPort,
            messageSize: messageSize,
            messageCount: messageCount,
            streamId: 2001,
            sessionId: 2
        )
        
        let publishResult = try await publishTest.runPublisherTest()
        publishResult.printResults()
        
        // 测试2: 零拷贝性能
        let zeroCopyTest = AeronPerformanceTest(
            host: publishHost,
            port: publishPort,
            messageSize: messageSize,
            messageCount: messageCount / 2, // 较少消息用于零拷贝测试
            streamId: 2002,
            sessionId: 3
        )
        
        let zeroCopyResult = try await zeroCopyTest.runZeroCopyTest()
        zeroCopyResult.printResults()
        
        // 测试3: 订阅性能 (模拟接收)
        print("💡 订阅测试需要外部发布者，跳过自动测试")
        print("使用以下命令启动订阅测试:")
        print("swift run AeronSwiftTest aeron_subscriber \(subscribePort) \(messageCount)")
        print("")
        
        // 总结
        print("📊 双向性能总结:")
        let avgPublishThroughput = Double(publishResult.totalBytes) / 1024.0 / 1024.0 / publishResult.duration
        let avgZeroCopyThroughput = Double(zeroCopyResult.totalBytes) / 1024.0 / 1024.0 / zeroCopyResult.duration
        
        print("- 标准发布: \(String(format: "%.2f", avgPublishThroughput)) MB/s")
        print("- 零拷贝发布: \(String(format: "%.2f", avgZeroCopyThroughput)) MB/s")
        print("- 零拷贝提升: \(String(format: "%.1f", avgZeroCopyThroughput / avgPublishThroughput))x")
        print("")
    }
}