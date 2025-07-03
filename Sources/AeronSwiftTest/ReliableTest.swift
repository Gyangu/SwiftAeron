import Foundation
import SwiftAeronClient

/// 可靠性Aeron协议测试
struct ReliableAeronTest {
    
    static func runReliabilityTest(host: String, port: UInt16, messageSize: Int, messageCount: Int) async throws {
        print("=== Reliable Aeron Test ===")
        print("Host: \(host)")
        print("Port: \(port)")
        print("Message Size: \(messageSize) bytes")
        print("Message Count: \(messageCount)")
        print("")
        
        let client = ReliableAeronClient(host: host, port: port)
        
        do {
            try await client.connect()
            print("✅ Connected to reliable Aeron endpoint")
            
            let testData = Data(repeating: 42, count: messageSize)
            let startTime = Date()
            
            print("Sending \(messageCount) reliable messages...")
            
            for i in 0..<messageCount {
                try await client.sendReliable(testData, sessionId: 1, streamId: 1001)
                
                if i % 10 == 0 {
                    let stats = client.getStatistics()
                    print("Sent \(i + 1) messages, pending: \(stats.pendingMessages)")
                }
                
                // 小延迟以观察可靠性机制
                if i % 20 == 0 {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
            }
            
            print("All messages sent, waiting for ACKs...")
            
            // 等待所有ACK
            var maxWait = 30 // 最多等待30秒
            while maxWait > 0 {
                let stats = client.getStatistics()
                if stats.pendingMessages == 0 {
                    print("✅ All messages acknowledged!")
                    break
                }
                
                print("Waiting for ACKs... pending: \(stats.pendingMessages)")
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                maxWait -= 1
            }
            
            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)
            let totalBytes = messageSize * messageCount
            let throughputMBps = Double(totalBytes) / 1024.0 / 1024.0 / duration
            
            print("\n=== Reliable Test Results ===")
            print("Duration: \(String(format: "%.2f", duration))s")
            print("Throughput: \(String(format: "%.2f", throughputMBps)) MB/s")
            
            let finalStats = client.getStatistics()
            finalStats.printStatistics()
            
            client.disconnect()
            
        } catch {
            print("❌ Test failed: \(error)")
            client.disconnect()
            throw error
        }
    }
    
    static func runReliableReceiver(port: UInt16, expectedMessages: Int) async throws {
        print("=== Reliable Aeron Receiver ===")
        print("Port: \(port)")
        print("Expected messages: \(expectedMessages)")
        print("")
        
        let receiver = try ReliableAeronReceiver(port: port)
        
        var receivedCount = 0
        var totalBytes = 0
        let startTime = Date()
        var firstMessageTime: Date?
        var lastSequence: UInt32 = 0
        var duplicateCount = 0
        var outOfOrderCount = 0
        
        receiver.onDataReceived = { data, sequenceNumber, sessionId, streamId in
            if firstMessageTime == nil {
                firstMessageTime = Date()
                print("First message received")
            }
            
            receivedCount += 1
            totalBytes += data.count
            
            // 检查顺序
            if sequenceNumber != lastSequence {
                if sequenceNumber < lastSequence {
                    duplicateCount += 1
                } else if sequenceNumber > lastSequence + 1 {
                    outOfOrderCount += 1
                }
            }
            lastSequence = sequenceNumber
            
            if receivedCount % 10 == 0 {
                print("Received \(receivedCount) messages, seq: \(sequenceNumber), session: \(sessionId), stream: \(streamId)")
            }
            
            // 验证数据内容
            if receivedCount <= 3 && !data.isEmpty {
                let firstByte = data[0]
                let lastByte = data[data.count - 1]
                print("  Data verification: first=\(firstByte), last=\(lastByte), size=\(data.count)")
            }
        }
        
        receiver.onFrameReceived = { frameType, sequenceNumber, sessionId, streamId in
            switch frameType {
            case .data:
                break // 已在onDataReceived处理
            case .ack:
                print("📨 Sent ACK for sequence \(sequenceNumber)")
            case .heartbeat:
                print("💓 Heartbeat from session \(sessionId)")
            case .nak:
                print("❌ NAK for sequence \(sequenceNumber)")
            case .flowControl:
                print("🔄 Flow control from session \(sessionId)")
            }
        }
        
        try await receiver.startListening()
        print("✅ Reliable receiver started, waiting for messages...")
        
        // 等待接收完成
        var waitTime = 0
        while receivedCount < expectedMessages && waitTime < 60 {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            waitTime += 1
            
            if waitTime % 10 == 0 {
                let stats = receiver.getStatistics()
                stats.printStatistics()
            }
        }
        
        receiver.stopListening()
        
        if let firstTime = firstMessageTime {
            let duration = Date().timeIntervalSince(firstTime)
            let throughputMBps = Double(totalBytes) / 1024.0 / 1024.0 / duration
            let messagesPerSecond = Double(receivedCount) / duration
            
            print("\n=== Reliable Receiver Results ===")
            print("Total messages: \(receivedCount)")
            print("Total bytes: \(totalBytes) (\(String(format: "%.2f", Double(totalBytes) / 1024.0 / 1024.0)) MB)")
            print("Duration: \(String(format: "%.2f", duration))s")
            print("Throughput: \(String(format: "%.2f", throughputMBps)) MB/s")
            print("Messages/sec: \(String(format: "%.2f", messagesPerSecond))")
            print("")
            print("=== Reliability Metrics ===")
            print("Duplicates detected: \(duplicateCount)")
            print("Out-of-order detected: \(outOfOrderCount)")
            print("Message loss: \(expectedMessages - receivedCount)")
            print("Success rate: \(String(format: "%.1f", Double(receivedCount) / Double(expectedMessages) * 100))%")
            
            let finalStats = receiver.getStatistics()
            finalStats.printStatistics()
        }
    }
    
    static func runLossSimulationTest(host: String, port: UInt16, messageSize: Int, messageCount: Int, lossRate: Double) async throws {
        print("=== Loss Simulation Test ===")
        print("Simulating \(String(format: "%.1f", lossRate * 100))% packet loss")
        print("")
        
        // 这个测试需要在网络层模拟丢包
        // 实际实现中，可以在发送时随机跳过某些消息来模拟丢包
        // 然后观察重传机制是否工作
        
        let client = ReliableAeronClient(host: host, port: port)
        
        try await client.connect()
        print("Connected for loss simulation test")
        
        let testData = Data(repeating: 99, count: messageSize)
        var simulatedLosses = 0
        
        for i in 0..<messageCount {
            // 模拟丢包
            if Double.random(in: 0...1) < lossRate {
                simulatedLosses += 1
                print("🔥 Simulating loss for message \(i)")
                continue
            }
            
            try await client.sendReliable(testData, sessionId: 2, streamId: 2001)
            
            if i % 10 == 0 {
                print("Sent \(i - simulatedLosses) out of \(i + 1) messages (simulated \(simulatedLosses) losses)")
            }
        }
        
        print("\n=== Loss Simulation Results ===")
        print("Total messages: \(messageCount)")
        print("Simulated losses: \(simulatedLosses)")
        print("Actually sent: \(messageCount - simulatedLosses)")
        print("Loss rate: \(String(format: "%.1f", Double(simulatedLosses) / Double(messageCount) * 100))%")
        
        // 等待重传完成
        print("Waiting for retransmissions...")
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
        
        let stats = client.getStatistics()
        stats.printStatistics()
        
        client.disconnect()
    }
}