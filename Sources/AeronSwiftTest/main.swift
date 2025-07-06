import Foundation
import SwiftAeronClient

struct AeronSwiftTest {
    static func main() async {
        let args = CommandLine.arguments
        
        guard args.count >= 2 else {
            print("Usage: AeronSwiftTest <mode> [options]")
            print("Modes:")
            print("  sender <host> <port> <message_size> <message_count>")
            print("  receiver <port>")
            print("  performance <host> <port> <message_size> <message_count>")
            print("  reliable_sender <host> <port> <message_size> <message_count>")
            print("  reliable_receiver <port> <expected_messages>")
            print("  loss_test <host> <port> <message_size> <message_count> <loss_rate>")
            print("  aeron_publisher <host> <port> <message_size> <message_count>")
            print("  aeron_subscriber <port> <expected_messages>")
            print("  aeron_zerocopy <host> <port> <message_size> <message_count>")
            print("  aeron_bidirectional <pub_host> <pub_port> <sub_port> <msg_size> <msg_count>")
            print("  aeron_compatible_pub <host> <port> <stream_id> <session_id> <msg_size> <msg_count>")
            print("  aeron_compatible_sub <port> <stream_id> <expected_messages>")
            print("  aeron_compatible_bidir <pub_host> <pub_port> <sub_port> <stream_id> <session_id> <msg_size> <msg_count>")
            print("  aeron_benchmark <host> <port> <stream_id> <session_id>")
            print("  hp_aeron_pub <host> <port> <stream_id> <session_id> <msg_size> <msg_count> [batch_size]")
            print("  hp_aeron_sub <port> <stream_id> <expected_messages>")
            print("  hp_aeron_benchmark <host> <port> <stream_id> <session_id>")
            print("  hp_aeron_bidir <pub_host> <pub_port> <sub_port> <stream_id> <session_id> <msg_size> <msg_count>")
            print("  optimized_aeron <host> <port> <stream_id> <session_id> <msg_size> <msg_count>")
            print("  bottleneck_optimized <host> <port> <stream_id> <session_id> <msg_size> <msg_count>")
            print("  bidirectional_optimized <pub_host> <pub_port> <sub_port> <stream_id> <session_id> <msg_size> <msg_count>")
            print("  ipc_aeron <socket_path> <stream_id> <session_id> <msg_size> <msg_count>")
            print("  swift_ipc_receiver <socket_path> <expected_count>")
            return
        }
        
        let mode = args[1]
        
        do {
            switch mode {
            case "sender":
                try await runSender(args: Array(args.dropFirst(2)))
            case "receiver":
                try await runReceiver(args: Array(args.dropFirst(2)))
            case "performance":
                try await runPerformanceTest(args: Array(args.dropFirst(2)))
            case "reliable_sender":
                try await runReliableSender(args: Array(args.dropFirst(2)))
            case "reliable_receiver":
                try await runReliableReceiver(args: Array(args.dropFirst(2)))
            case "loss_test":
                try await runLossTest(args: Array(args.dropFirst(2)))
            case "aeron_publisher":
                try await runAeronPublisher(args: Array(args.dropFirst(2)))
            case "aeron_subscriber":
                try await runAeronSubscriber(args: Array(args.dropFirst(2)))
            case "aeron_zerocopy":
                try await runAeronZeroCopy(args: Array(args.dropFirst(2)))
            case "aeron_bidirectional":
                try await runAeronBidirectional(args: Array(args.dropFirst(2)))
            case "aeron_compatible_pub":
                try await runAeronCompatiblePublisher(args: Array(args.dropFirst(2)))
            case "aeron_compatible_sub":
                try await runAeronCompatibleSubscriber(args: Array(args.dropFirst(2)))
            case "aeron_compatible_bidir":
                try await runAeronCompatibleBidirectional(args: Array(args.dropFirst(2)))
            case "aeron_benchmark":
                try await runAeronBenchmark(args: Array(args.dropFirst(2)))
            case "hp_aeron_pub":
                try await runHighPerformancePublisher(args: Array(args.dropFirst(2)))
            case "hp_aeron_sub":
                try await runHighPerformanceSubscriber(args: Array(args.dropFirst(2)))
            case "hp_aeron_benchmark":
                try await runHighPerformanceBenchmark(args: Array(args.dropFirst(2)))
            case "hp_aeron_bidir":
                try await runHighPerformanceBidirectional(args: Array(args.dropFirst(2)))
            case "optimized_aeron":
                try await runOptimizedAeron(args: Array(args.dropFirst(2)))
            case "bottleneck_optimized":
                try await runBottleneckOptimized(args: Array(args.dropFirst(2)))
            case "bidirectional_optimized":
                try await runBidirectionalOptimized(args: Array(args.dropFirst(2)))
            case "ipc_aeron":
                try await runIPCAeron(args: Array(args.dropFirst(2)))
            case "swift_ipc_receiver":
                try await runSwiftIPCReceiver(args: Array(args.dropFirst(2)))
            default:
                print("Unknown mode: \(mode)")
            }
        } catch {
            print("Error: \(error)")
        }
    }
    
    static func runSender(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let messageSize = Int(args.count > 2 ? args[2] : "1048576") ?? 1048576
        let messageCount = Int(args.count > 3 ? args[3] : "100") ?? 100
        
        print("Swift Aeron Sender")
        print("Host: \(host)")
        print("Port: \(port)")
        print("Message Size: \(messageSize) bytes")
        print("Message Count: \(messageCount)")
        
        let client = SwiftAeronClient(host: host, port: port)
        try await client.connect()
        
        let testData = Data(repeating: 42, count: messageSize)
        let startTime = Date()
        
        for i in 0..<messageCount {
            try await client.sendData(testData, sessionId: 1, streamId: 1001)
            
            if i % 10 == 0 {
                print("Sent \(i + 1) messages")
            }
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        let totalBytes = messageSize * messageCount
        let throughputMBps = Double(totalBytes) / 1024.0 / 1024.0 / duration
        
        print("\n=== Results ===")
        print("Duration: \(String(format: "%.2f", duration))s")
        print("Throughput: \(String(format: "%.2f", throughputMBps)) MB/s")
        
        client.disconnect()
    }
    
    static func runReceiver(args: [String]) async throws {
        let port = UInt16(args.count > 0 ? args[0] : "40001") ?? 40001
        
        print("Swift Aeron Receiver")
        print("Port: \(port)")
        print("Waiting for messages...")
        
        let receiver = try SwiftAeronReceiver(port: port)
        
        var receivedCount = 0
        var totalBytes = 0
        let startTime = Date()
        var firstMessageTime: Date?
        
        receiver.onDataReceived = { data, sessionId, streamId in
            if firstMessageTime == nil {
                firstMessageTime = Date()
            }
            
            receivedCount += 1
            totalBytes += data.count
            
            if receivedCount % 10 == 0 {
                print("Received \(receivedCount) messages, \(totalBytes) bytes")
            }
        }
        
        try await receiver.startListening()
        print("Receiver started, listening for Aeron frames...")
        
        // Keep running for a while
        try await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
        
        receiver.stopListening()
        
        if let firstTime = firstMessageTime {
            let duration = Date().timeIntervalSince(firstTime)
            let throughputMBps = Double(totalBytes) / 1024.0 / 1024.0 / duration
            
            print("\n=== Receiver Results ===")
            print("Total messages: \(receivedCount)")
            print("Total bytes: \(totalBytes)")
            print("Duration: \(String(format: "%.2f", duration))s")
            print("Throughput: \(String(format: "%.2f", throughputMBps)) MB/s")
        }
    }
    
    static func runPerformanceTest(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let messageSize = Int(args.count > 2 ? args[2] : "1048576") ?? 1048576
        let messageCount = Int(args.count > 3 ? args[3] : "100") ?? 100
        
        print("Swift Aeron Performance Test")
        print("Connecting to \(host):\(port)")
        
        let test = AeronPerformanceTest(
            host: host,
            port: port,
            messageSize: messageSize,
            messageCount: messageCount
        )
        
        let result = try await test.runPublisherTest()
        result.printResults()
    }
    
    static func runReliableSender(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let messageSize = Int(args.count > 2 ? args[2] : "1024") ?? 1024
        let messageCount = Int(args.count > 3 ? args[3] : "50") ?? 50
        
        try await ReliableAeronTest.runReliabilityTest(
            host: host,
            port: port,
            messageSize: messageSize,
            messageCount: messageCount
        )
    }
    
    static func runReliableReceiver(args: [String]) async throws {
        let port = UInt16(args.count > 0 ? args[0] : "40001") ?? 40001
        let expectedMessages = Int(args.count > 1 ? args[1] : "50") ?? 50
        
        try await ReliableAeronTest.runReliableReceiver(
            port: port,
            expectedMessages: expectedMessages
        )
    }
    
    static func runLossTest(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let messageSize = Int(args.count > 2 ? args[2] : "1024") ?? 1024
        let messageCount = Int(args.count > 3 ? args[3] : "100") ?? 100
        let lossRate = Double(args.count > 4 ? args[4] : "0.1") ?? 0.1
        
        try await ReliableAeronTest.runLossSimulationTest(
            host: host,
            port: port,
            messageSize: messageSize,
            messageCount: messageCount,
            lossRate: lossRate
        )
    }
    
    // MARK: - 真正的Aeron测试方法
    
    static func runAeronPublisher(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let messageSize = Int(args.count > 2 ? args[2] : "65536") ?? 65536  // 64KB
        let messageCount = Int(args.count > 3 ? args[3] : "1000") ?? 1000
        
        let test = AeronPerformanceTest(
            host: host,
            port: port,
            messageSize: messageSize,
            messageCount: messageCount
        )
        
        let result = try await test.runPublisherTest()
        result.printResults()
    }
    
    static func runAeronSubscriber(args: [String]) async throws {
        let port = UInt16(args.count > 0 ? args[0] : "40001") ?? 40001
        let expectedMessages = Int(args.count > 1 ? args[1] : "1000") ?? 1000
        
        let test = AeronPerformanceTest(
            host: "127.0.0.1",
            port: port,
            messageSize: 1024,
            messageCount: 1
        )
        
        let result = try await test.runSubscriberTest(expectedMessages: expectedMessages)
        result.printResults()
    }
    
    static func runAeronZeroCopy(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let messageSize = Int(args.count > 2 ? args[2] : "65536") ?? 65536
        let messageCount = Int(args.count > 3 ? args[3] : "1000") ?? 1000
        
        let test = AeronPerformanceTest(
            host: host,
            port: port,
            messageSize: messageSize,
            messageCount: messageCount
        )
        
        let result = try await test.runZeroCopyTest()
        result.printResults()
    }
    
    static func runAeronBidirectional(args: [String]) async throws {
        let publishHost = args.count > 0 ? args[0] : "127.0.0.1"
        let publishPort = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let subscribePort = UInt16(args.count > 2 ? args[2] : "40002") ?? 40002
        let messageSize = Int(args.count > 3 ? args[3] : "65536") ?? 65536
        let messageCount = Int(args.count > 4 ? args[4] : "1000") ?? 1000
        
        try await AeronBidirectionalTest.runBidirectionalPerformanceTest(
            publishHost: publishHost,
            publishPort: publishPort,
            subscribePort: subscribePort,
            messageSize: messageSize,
            messageCount: messageCount
        )
    }
    
    // MARK: - Aeron兼容性测试方法
    
    static func runAeronCompatiblePublisher(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let streamId = UInt32(args.count > 2 ? args[2] : "1001") ?? 1001
        let sessionId = UInt32(args.count > 3 ? args[3] : "1") ?? 1
        let messageSize = Int(args.count > 4 ? args[4] : "1024") ?? 1024
        let messageCount = Int(args.count > 5 ? args[5] : "10000") ?? 10000
        
        try await AeronCompatibilityTest.runCompatiblePublisher(
            host: host,
            port: port,
            streamId: streamId,
            sessionId: sessionId,
            messageSize: messageSize,
            messageCount: messageCount
        )
    }
    
    static func runAeronCompatibleSubscriber(args: [String]) async throws {
        let port = UInt16(args.count > 0 ? args[0] : "40001") ?? 40001
        let streamId = UInt32(args.count > 1 ? args[1] : "1001") ?? 1001
        let expectedMessages = Int(args.count > 2 ? args[2] : "10000") ?? 10000
        
        try await AeronCompatibilityTest.runCompatibleSubscriber(
            port: port,
            streamId: streamId,
            expectedMessages: expectedMessages
        )
    }
    
    static func runAeronCompatibleBidirectional(args: [String]) async throws {
        let publishHost = args.count > 0 ? args[0] : "127.0.0.1"
        let publishPort = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let subscribePort = UInt16(args.count > 2 ? args[2] : "40002") ?? 40002
        let streamId = UInt32(args.count > 3 ? args[3] : "1001") ?? 1001
        let sessionId = UInt32(args.count > 4 ? args[4] : "1") ?? 1
        let messageSize = Int(args.count > 5 ? args[5] : "1024") ?? 1024
        let messageCount = Int(args.count > 6 ? args[6] : "10000") ?? 10000
        
        try await AeronCompatibilityTest.runBidirectionalCompatibilityTest(
            publishHost: publishHost,
            publishPort: publishPort,
            subscribePort: subscribePort,
            streamId: streamId,
            sessionId: sessionId,
            messageSize: messageSize,
            messageCount: messageCount
        )
    }
    
    static func runAeronBenchmark(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let streamId = UInt32(args.count > 2 ? args[2] : "1001") ?? 1001
        let sessionId = UInt32(args.count > 3 ? args[3] : "1") ?? 1
        
        try await AeronCompatibilityTest.runPerformanceBenchmark(
            host: host,
            port: port,
            streamId: streamId,
            sessionId: sessionId
        )
    }
    
    // MARK: - 高性能测试方法
    
    static func runHighPerformancePublisher(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let streamId = UInt32(args.count > 2 ? args[2] : "1001") ?? 1001
        let sessionId = UInt32(args.count > 3 ? args[3] : "1") ?? 1
        let messageSize = Int(args.count > 4 ? args[4] : "1024") ?? 1024
        let messageCount = Int(args.count > 5 ? args[5] : "10000") ?? 10000
        let batchSize = Int(args.count > 6 ? args[6] : "1000") ?? 1000
        
        try await HighPerformanceAeronTest.runHighPerformancePublisher(
            host: host,
            port: port,
            streamId: streamId,
            sessionId: sessionId,
            messageSize: messageSize,
            messageCount: messageCount,
            batchSize: batchSize
        )
    }
    
    static func runHighPerformanceSubscriber(args: [String]) async throws {
        let port = UInt16(args.count > 0 ? args[0] : "40001") ?? 40001
        let streamId = UInt32(args.count > 1 ? args[1] : "1001") ?? 1001
        let expectedMessages = Int(args.count > 2 ? args[2] : "10000") ?? 10000
        
        try await HighPerformanceAeronTest.runHighPerformanceSubscriber(
            port: port,
            streamId: streamId,
            expectedMessages: expectedMessages
        )
    }
    
    static func runHighPerformanceBenchmark(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let streamId = UInt32(args.count > 2 ? args[2] : "1001") ?? 1001
        let sessionId = UInt32(args.count > 3 ? args[3] : "1") ?? 1
        
        try await HighPerformanceAeronTest.runHighPerformanceBenchmark(
            host: host,
            port: port,
            streamId: streamId,
            sessionId: sessionId
        )
    }
    
    static func runHighPerformanceBidirectional(args: [String]) async throws {
        let publishHost = args.count > 0 ? args[0] : "127.0.0.1"
        let publishPort = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let subscribePort = UInt16(args.count > 2 ? args[2] : "40002") ?? 40002
        let streamId = UInt32(args.count > 3 ? args[3] : "1001") ?? 1001
        let sessionId = UInt32(args.count > 4 ? args[4] : "1") ?? 1
        let messageSize = Int(args.count > 5 ? args[5] : "1024") ?? 1024
        let messageCount = Int(args.count > 6 ? args[6] : "10000") ?? 10000
        
        try await HighPerformanceAeronTest.runHighPerformanceBidirectional(
            publishHost: publishHost,
            publishPort: publishPort,
            subscribePort: subscribePort,
            streamId: streamId,
            sessionId: sessionId,
            messageSize: messageSize,
            messageCount: messageCount
        )
    }
    
    static func runOptimizedAeron(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let streamId = UInt32(args.count > 2 ? args[2] : "1001") ?? 1001
        let sessionId = UInt32(args.count > 3 ? args[3] : "1") ?? 1
        let messageSize = Int(args.count > 4 ? args[4] : "1024") ?? 1024
        let messageCount = Int(args.count > 5 ? args[5] : "10000") ?? 10000
        
        try await OptimizedAeronTest.runOptimizedTest(
            host: host,
            port: port,
            streamId: streamId,
            sessionId: sessionId,
            messageSize: messageSize,
            messageCount: messageCount
        )
    }
    
    static func runBottleneckOptimized(args: [String]) async throws {
        let host = args.count > 0 ? args[0] : "127.0.0.1"
        let port = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let streamId = UInt32(args.count > 2 ? args[2] : "1001") ?? 1001
        let sessionId = UInt32(args.count > 3 ? args[3] : "1") ?? 1
        let messageSize = Int(args.count > 4 ? args[4] : "1024") ?? 1024
        let messageCount = Int(args.count > 5 ? args[5] : "10000") ?? 10000
        
        try await BottleneckOptimizedTest.runOptimizedPerformanceTest(
            host: host,
            port: port,
            streamId: streamId,
            sessionId: sessionId,
            messageSize: messageSize,
            messageCount: messageCount
        )
    }
    
    static func runBidirectionalOptimized(args: [String]) async throws {
        let publishHost = args.count > 0 ? args[0] : "127.0.0.1"
        let publishPort = UInt16(args.count > 1 ? args[1] : "40001") ?? 40001
        let subscribePort = UInt16(args.count > 2 ? args[2] : "40002") ?? 40002
        let streamId = UInt32(args.count > 3 ? args[3] : "1001") ?? 1001
        let sessionId = UInt32(args.count > 4 ? args[4] : "1") ?? 1
        let messageSize = Int(args.count > 5 ? args[5] : "1024") ?? 1024
        let messageCount = Int(args.count > 6 ? args[6] : "5000") ?? 5000
        
        try await BidirectionalOptimizedTest.runBidirectionalPerformanceTest(
            publishHost: publishHost,
            publishPort: publishPort,
            subscribePort: subscribePort,
            streamId: streamId,
            sessionId: sessionId,
            messageSize: messageSize,
            messageCount: messageCount
        )
    }
    
    static func runIPCAeron(args: [String]) async throws {
        let socketPath = args.count > 0 ? args[0] : "/tmp/aeron_ipc.sock"
        let streamId = UInt32(args.count > 1 ? args[1] : "1001") ?? 1001
        let sessionId = UInt32(args.count > 2 ? args[2] : "1") ?? 1
        let messageSize = Int(args.count > 3 ? args[3] : "1024") ?? 1024
        let messageCount = Int(args.count > 4 ? args[4] : "10000") ?? 10000
        
        try await IPCTestCommand.runIPCPerformanceTest(
            socketPath: socketPath,
            streamId: streamId,
            sessionId: sessionId,
            messageSize: messageSize,
            messageCount: messageCount
        )
    }
    
    static func runSwiftIPCReceiver(args: [String]) async throws {
        let socketPath = args.count > 0 ? args[0] : "/tmp/swift_ipc.sock"
        let expectedCount = Int(args.count > 1 ? args[1] : "10000") ?? 10000
        
        try await SwiftIPCReceiverTest.runSwiftIPCReceiver(
            socketPath: socketPath,
            expectedCount: expectedCount
        )
    }
}

// Execute the main function
await AeronSwiftTest.main()