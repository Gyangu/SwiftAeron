import Foundation
import SwiftAeronClient

/// Aeron兼容性测试 - 与aeron-rs双向通信
public struct AeronCompatibilityTest {
    
    /// 兼容性发布测试
    public static func runCompatiblePublisher(host: String, port: UInt16, streamId: UInt32, sessionId: UInt32, messageSize: Int, messageCount: Int) async throws {
        print("🚀 启动Aeron兼容发布测试")
        print("目标: \(host):\(port)")
        print("流ID: \(streamId), 会话ID: \(sessionId)")
        print("消息大小: \(messageSize) bytes, 数量: \(messageCount)")
        print("")
        
        let publication = AeronCompatiblePublication(
            streamId: streamId,
            sessionId: sessionId,
            termBufferLength: AeronProtocolSpec.TERM_DEFAULT_LENGTH,
            host: host,
            port: port
        )
        
        try await publication.connect()
        print("✅ 已连接到Aeron兼容端点")
        
        // 等待连接稳定
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        
        let testData = createTestData(size: messageSize)
        let startTime = Date()
        var successCount = 0
        var totalBytes = 0
        
        print("📤 开始发布消息...")
        
        for i in 0..<messageCount {
            let position = await publication.offer(testData)
            
            if position > 0 {
                successCount += 1
                totalBytes += messageSize
                
                if i % (messageCount / 10) == 0 {
                    print("已发布: \(i + 1)/\(messageCount) 消息, 位置: \(position)")
                }
            } else {
                print("❌ 发布失败: 消息\(i), 位置\(position)")
            }
            
            // 适当延迟避免压倒接收方
            if i % 50 == 0 {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        // 等待最后的状态消息
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        
        publication.close()
        
        print("\n=== Aeron兼容发布结果 ===")
        print("发布消息: \(successCount)/\(messageCount)")
        print("总字节数: \(String(format: "%.2f", Double(totalBytes) / 1024.0 / 1024.0)) MB")
        print("持续时间: \(String(format: "%.2f", duration))s")
        
        if duration > 0 {
            let throughput = Double(totalBytes) / 1024.0 / 1024.0 / duration
            let messageRate = Double(successCount) / duration
            print("吞吐量: \(String(format: "%.2f", throughput)) MB/s")
            print("消息速率: \(String(format: "%.0f", messageRate)) 消息/秒")
        }
        
        let successRate = Double(successCount) / Double(messageCount) * 100
        print("成功率: \(String(format: "%.1f", successRate))%")
        print("最终位置: \(publication.getPosition())")
        print("")
    }
    
    /// 兼容性订阅测试
    public static func runCompatibleSubscriber(port: UInt16, streamId: UInt32, expectedMessages: Int, timeoutSeconds: Int = 60) async throws {
        print("🎧 启动Aeron兼容订阅测试")
        print("监听端口: \(port)")
        print("流ID: \(streamId)")
        print("期望消息: \(expectedMessages)")
        print("")
        
        let subscription = try AeronCompatibleSubscription(
            streamId: streamId,
            sessionId: nil, // 接受所有会话
            port: port
        )
        
        var receivedCount = 0
        var totalBytes = 0
        var firstMessageTime: Date?
        var lastMessageTime: Date?
        var sessionStats: [UInt32: Int] = [:]
        var lastPositions: [UInt32: Int64] = [:]
        
        // 设置fragment handler
        subscription.fragmentHandler = { data, sessionId, streamId, position in
            if firstMessageTime == nil {
                firstMessageTime = Date()
                print("📨 收到第一条消息")
            }
            
            lastMessageTime = Date()
            receivedCount += 1
            totalBytes += data.count
            sessionStats[sessionId, default: 0] += 1
            lastPositions[sessionId] = position
            
            if receivedCount % (expectedMessages / 10) == 0 {
                print("已接收: \(receivedCount)/\(expectedMessages) 消息")
            }
            
            // 验证数据内容
            if receivedCount <= 3 {
                let pattern = data.prefix(4)
                print("  数据模式: \(pattern.map { String(format: "%02x", $0) }.joined())")
            }
        }
        
        try await subscription.startListening()
        print("✅ 开始监听Aeron兼容消息")
        
        let startTime = Date()
        var elapsedTime = 0
        
        // 主接收循环
        while receivedCount < expectedMessages && elapsedTime < timeoutSeconds {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            elapsedTime = Int(Date().timeIntervalSince(startTime))
            
            if elapsedTime % 10 == 0 && elapsedTime > 0 {
                print("⏱️ 已等待 \(elapsedTime)s, 接收 \(receivedCount)/\(expectedMessages)")
            }
        }
        
        subscription.stopListening()
        
        print("\n=== Aeron兼容订阅结果 ===")
        print("接收消息: \(receivedCount)/\(expectedMessages)")
        print("总字节数: \(String(format: "%.2f", Double(totalBytes) / 1024.0 / 1024.0)) MB")
        
        if let firstTime = firstMessageTime {
            let duration = (lastMessageTime ?? firstTime).timeIntervalSince(firstTime)
            print("接收持续时间: \(String(format: "%.2f", duration))s")
            
            if duration > 0 {
                let throughput = Double(totalBytes) / 1024.0 / 1024.0 / duration
                let messageRate = Double(receivedCount) / duration
                print("接收吞吐量: \(String(format: "%.2f", throughput)) MB/s")
                print("接收速率: \(String(format: "%.0f", messageRate)) 消息/秒")
            }
        }
        
        print("\n=== 会话统计 ===")
        for (sessionId, count) in sessionStats {
            let lastPos = lastPositions[sessionId] ?? 0
            print("会话 \(sessionId): \(count) 消息, 最终位置: \(lastPos)")
        }
        
        let successRate = Double(receivedCount) / Double(expectedMessages) * 100
        print("接收成功率: \(String(format: "%.1f", successRate))%")
        print("")
    }
    
    /// 双向兼容性测试
    public static func runBidirectionalCompatibilityTest(
        publishHost: String,
        publishPort: UInt16,
        subscribePort: UInt16,
        streamId: UInt32,
        sessionId: UInt32,
        messageSize: Int,
        messageCount: Int
    ) async throws {
        
        print("🔄 Aeron双向兼容性测试")
        print("发布目标: \(publishHost):\(publishPort)")
        print("订阅端口: \(subscribePort)")
        print("流ID: \(streamId), 会话ID: \(sessionId)")
        print("消息大小: \(messageSize) bytes, 数量: \(messageCount)")
        print("")
        
        // 测试1: Swift → aeron-rs
        print("==================== TEST 1: Swift → aeron-rs ====================")
        try await runCompatiblePublisher(
            host: publishHost,
            port: publishPort,
            streamId: streamId,
            sessionId: sessionId,
            messageSize: messageSize,
            messageCount: messageCount
        )
        
        // 等待一段时间
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2s
        
        // 测试2: aeron-rs → Swift
        print("==================== TEST 2: aeron-rs → Swift ====================")
        print("请启动aeron-rs发送端，目标端口: \(subscribePort)")
        print("等待接收来自aeron-rs的消息...")
        
        try await runCompatibleSubscriber(
            port: subscribePort,
            streamId: streamId,
            expectedMessages: messageCount
        )
        
        print("==================== 双向兼容性测试完成 ====================")
    }
    
    /// 性能基准测试
    public static func runPerformanceBenchmark(host: String, port: UInt16, streamId: UInt32, sessionId: UInt32) async throws {
        print("⚡ Aeron性能基准测试")
        print("")
        
        let messageSizes = [64, 256, 1024, 4096, 16384] // 不同消息大小
        let messageCount = 10000
        
        for messageSize in messageSizes {
            print("--- 消息大小: \(messageSize) bytes ---")
            
            let publication = AeronCompatiblePublication(
                streamId: streamId,
                sessionId: sessionId,
                host: host,
                port: port
            )
            
            try await publication.connect()
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms预热
            
            let testData = createTestData(size: messageSize)
            let startTime = Date()
            
            for i in 0..<messageCount {
                let _ = await publication.offer(testData)
                
                // 适当的批量控制
                if i % 100 == 0 {
                    try await Task.sleep(nanoseconds: 1_000_000) // 1ms
                }
            }
            
            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)
            let totalBytes = messageSize * messageCount
            let throughput = Double(totalBytes) / 1024.0 / 1024.0 / duration
            let messageRate = Double(messageCount) / duration
            
            print("  持续时间: \(String(format: "%.3f", duration))s")
            print("  吞吐量: \(String(format: "%.2f", throughput)) MB/s")
            print("  消息速率: \(String(format: "%.0f", messageRate)) 消息/秒")
            print("  平均延迟: \(String(format: "%.2f", duration * 1000 / Double(messageCount))) ms/消息")
            print("")
            
            publication.close()
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms间隔
        }
    }
    
    private static func createTestData(size: Int) -> Data {
        var data = Data(capacity: size)
        
        // 创建可识别的测试模式
        let patterns: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000) // 毫秒时间戳
        
        // 添加时间戳头部
        data.append(contentsOf: timestamp.littleEndian.bytes)
        
        // 填充模式数据
        var remainingSize = size - 8
        while remainingSize > 0 {
            let chunkSize = min(patterns.count, remainingSize)
            data.append(contentsOf: patterns.prefix(chunkSize))
            remainingSize -= chunkSize
        }
        
        return data
    }
}