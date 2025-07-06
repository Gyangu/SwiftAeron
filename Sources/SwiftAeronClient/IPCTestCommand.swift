import Foundation

/// IPC Aeron测试命令
public class IPCTestCommand {
    public static func runIPCPerformanceTest(
        socketPath: String,
        streamId: UInt32,
        sessionId: UInt32,
        messageSize: Int,
        messageCount: Int
    ) async throws {
        
        print("🔗 IPC Aeron性能测试")
        print("Socket路径: \\(socketPath)")
        print("流ID: \\(streamId), 会话ID: \\(sessionId)")
        print("消息大小: \\(messageSize) bytes, 数量: \\(messageCount)")
        print("目标: 实现Swift ↔ Rust IPC高性能通信\\n")
        
        let publication = SimpleIPCPublication(
            socketPath: socketPath,
            streamId: streamId,
            sessionId: sessionId
        )
        
        try await publication.connect()
        
        // 预热测试
        print("🔥 开始IPC预热...")
        let warmupData = Data(repeating: 0x41, count: 64)
        for i in 0..<100 {
            let result = await publication.offer(warmupData)
            if result < 0 {
                print("预热失败 at \\(i)")
                break
            }
        }
        
        // 短暂延迟让Rust接收器准备好
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        
        // 主要性能测试
        print("📊 开始主要IPC性能测试...")
        let testData = Data(repeating: 0x42, count: messageSize)
        let testStartTime = Date()
        
        for i in 0..<messageCount {
            let result = await publication.offer(testData)
            if result < 0 {
                print("❌ 发送失败 at \\(i)")
                break
            }
            
            if i % (messageCount / 10) == 0 {
                print("发送进度: \\(i)/\\(messageCount)")
            }
            
            // 小批量延迟，避免压垮接收器
            if i % 1000 == 0 && i > 0 {
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
        }
        
        // 额外延迟确保所有数据发送完成
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        let testDuration = Date().timeIntervalSince(testStartTime)
        let stats = publication.getPerformanceStats()
        
        stats.printStats()
        
        // IPC特定分析
        print("\\n🎯 IPC优化效果分析:")
        if stats.throughputMBps > 100 {
            print("✅ IPC性能优秀！远超网络通信")
        } else if stats.throughputMBps > 50 {
            print("🔄 IPC性能良好，接近预期")
        } else {
            print("❌ IPC性能需要进一步优化")
        }
        
        // 与网络和本地IPC对比
        let networkBaseline = 8.95    // 网络Aeron基准
        let unixSocketBaseline = 416.0 // Unix Socket基准
        let vsNetwork = stats.throughputMBps / networkBaseline
        let vsUnixSocket = stats.throughputMBps / unixSocketBaseline
        
        print("\\n📈 性能对比:")
        print("相对网络Aeron: \\(String(format: \"%.1f\", vsNetwork))倍")
        print("相对纯Unix Socket: \\(String(format: \"%.1f%%\", vsUnixSocket * 100))")
        
        if vsNetwork > 10 {
            print("🏆 IPC Aeron实现了显著的性能提升！")
        } else if vsNetwork > 5 {
            print("✅ IPC Aeron性能符合预期")
        } else {
            print("⚠️ IPC实现可能存在性能瓶颈")
        }
        
        publication.close()
    }
}