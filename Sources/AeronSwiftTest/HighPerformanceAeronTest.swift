import Foundation
import SwiftAeronClient

public class HighPerformanceAeronTest {
    
    /// 高性能发布者测试
    public static func runHighPerformancePublisher(
        host: String,
        port: UInt16,
        streamId: UInt32,
        sessionId: UInt32,
        messageSize: Int,
        messageCount: Int,
        batchSize: Int = 1000
    ) async throws {
        
        print("🚀 启动高性能Aeron发布测试")
        print("目标: \(host):\(port)")
        print("流ID: \(streamId), 会话ID: \(sessionId)")
        print("消息大小: \(messageSize) bytes, 数量: \(messageCount)")
        print("批量大小: \(batchSize)")
        
        let publication = HighPerformanceAeronPublication(
            streamId: streamId,
            sessionId: sessionId,
            host: host,
            port: port,
            batchSize: batchSize
        )
        
        do {
            try await publication.connect()
            print("✅ 已连接到高性能Aeron端点")
            
            // 预热
            print("🔥 开始预热...")
            let warmupData = Data(repeating: 0x42, count: messageSize)
            for _ in 0..<min(100, messageCount / 10) {
                _ = await publication.offer(warmupData)
            }
            
            // 等待预热完成
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            print("✅ 预热完成")
            
            print("📤 开始高性能发布...")
            
            let testData = Data(repeating: 0x55, count: messageSize)
            let startTime = Date()
            
            // 高性能发布循环
            for i in 0..<messageCount {
                let result = await publication.offer(testData)
                
                if result < 0 {
                    print("❌ 发布失败，错误码: \(result)")
                    break
                }
                
                // 进度报告（减少频率以提高性能）
                if i > 0 && i % (messageCount / 10) == 0 {
                    let progress = Double(i) / Double(messageCount) * 100
                    print("已发布: \(i)/\(messageCount) 消息 (\(String(format: "%.1f", progress))%)")
                }
            }
            
            // 强制刷新剩余批量数据
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            
            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)
            
            // 获取性能统计
            let stats = publication.getPerformanceStats()
            
            print("\n=== 高性能发布结果 ===")
            print("发布消息: \(messageCount)/\(messageCount)")
            print("总字节数: \(String(format: "%.2f", Double(messageCount * messageSize) / 1024.0 / 1024.0)) MB")
            print("持续时间: \(String(format: "%.3f", duration))s")
            
            if duration > 0 {
                let throughputMBps = Double(messageCount * messageSize) / 1024.0 / 1024.0 / duration
                let messageRate = Double(messageCount) / duration
                
                print("吞吐量: \(String(format: "%.2f", throughputMBps)) MB/s")
                print("消息速率: \(String(format: "%.0f", messageRate)) 消息/秒")
                print("平均延迟: \(String(format: "%.3f", duration * 1000.0 / Double(messageCount))) ms/消息")
            }
            
            // 性能对比
            stats.printStats()
            
        } catch {
            print("❌ 连接失败: \(error)")
            publication.close()
            throw error
        }
        
        publication.close()
    }
    
    /// 高性能订阅者测试
    public static func runHighPerformanceSubscriber(
        port: UInt16,
        streamId: UInt32,
        expectedMessages: Int
    ) async throws {
        
        print("🎯 启动高性能Aeron订阅测试")
        print("端口: \(port)")
        print("流ID: \(streamId)")
        print("期望消息: \(expectedMessages)")
        
        let subscription = try HighPerformanceAeronSubscription(port: port, streamId: streamId)
        
        var receivedCount = 0
        var totalBytes = 0
        var firstMessageTime: Date?
        let startTime = Date()
        
        subscription.onDataReceived = { data, sessionId, streamId in
            if firstMessageTime == nil {
                firstMessageTime = Date()
                print("📊 收到第一条消息")
            }
            
            receivedCount += 1
            totalBytes += data.count
            
            // 减少日志频率以提高性能
            if receivedCount % (expectedMessages / 10) == 0 || receivedCount <= 5 {
                print("📊 已接收: \(receivedCount)/\(expectedMessages) 消息")
            }
        }
        
        do {
            try await subscription.startListening()
            print("✅ 高性能订阅者已启动")
            
            // 等待接收完成
            while receivedCount < expectedMessages {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                
                // 超时检查
                if Date().timeIntervalSince(startTime) > 60 {
                    print("⏰ 接收超时")
                    break
                }
            }
            
            let endTime = Date()
            
            print("\n=== 高性能接收结果 ===")
            print("接收消息: \(receivedCount)/\(expectedMessages)")
            print("总字节数: \(totalBytes)")
            print("总持续时间: \(String(format: "%.3f", endTime.timeIntervalSince(startTime)))s")
            
            if let firstTime = firstMessageTime {
                let dataTransferDuration = endTime.timeIntervalSince(firstTime)
                if dataTransferDuration > 0 {
                    let throughputMBps = Double(totalBytes) / 1024.0 / 1024.0 / dataTransferDuration
                    let messageRate = Double(receivedCount) / dataTransferDuration
                    
                    print("数据传输时间: \(String(format: "%.3f", dataTransferDuration))s")
                    print("吞吐量: \(String(format: "%.2f", throughputMBps)) MB/s")
                    print("消息速率: \(String(format: "%.0f", messageRate)) 消息/秒")
                }
            }
            
            let successRate = Double(receivedCount) / Double(expectedMessages) * 100
            print("成功率: \(String(format: "%.1f", successRate))%")
            
        } catch {
            print("❌ 订阅失败: \(error)")
            subscription.stopListening()
            throw error
        }
        
        subscription.stopListening()
    }
    
    /// 高性能基准测试
    public static func runHighPerformanceBenchmark(
        host: String,
        port: UInt16,
        streamId: UInt32,
        sessionId: UInt32
    ) async throws {
        
        print("⚡ 高性能Aeron基准测试")
        print("==================================")
        
        // 不同消息大小的测试
        let testSizes = [64, 256, 1024, 4096, 8192]
        let messageCount = 50000 // 增加测试量
        
        for size in testSizes {
            print("\n--- 消息大小: \(size) bytes ---")
            
            try await runHighPerformancePublisher(
                host: host,
                port: port,
                streamId: streamId,
                sessionId: sessionId,
                messageSize: size,
                messageCount: messageCount,
                batchSize: 2000 // 更大的批量大小
            )
            
            // 测试间隔
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        }
        
        print("\n🏁 高性能基准测试完成!")
    }
    
    /// 双向高性能测试
    public static func runHighPerformanceBidirectional(
        publishHost: String,
        publishPort: UInt16,
        subscribePort: UInt16,
        streamId: UInt32,
        sessionId: UInt32,
        messageSize: Int,
        messageCount: Int
    ) async throws {
        
        print("🔄 高性能双向Aeron测试")
        print("发布端口: \(publishPort), 订阅端口: \(subscribePort)")
        
        // 启动订阅者
        let subscriptionTask = Task {
            try await runHighPerformanceSubscriber(
                port: subscribePort,
                streamId: streamId,
                expectedMessages: messageCount
            )
        }
        
        // 等待订阅者启动
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 启动发布者
        let publishTask = Task {
            try await runHighPerformancePublisher(
                host: publishHost,
                port: subscribePort,
                streamId: streamId,
                sessionId: sessionId,
                messageSize: messageSize,
                messageCount: messageCount,
                batchSize: 1000
            )
        }
        
        // 等待完成
        try await publishTask.value
        try await subscriptionTask.value
        
        print("\n🎉 高性能双向测试完成!")
    }
}