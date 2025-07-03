import Foundation
import SwiftAeronClient

@main
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
        
        let result = try await test.runTest()
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
}