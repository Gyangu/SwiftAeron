# SwiftAeron Examples

⚠️ **AI-Generated Code Examples** - Review carefully before use.

## Basic Examples

### Simple Message Sending

```swift
import SwiftAeronClient

func sendSimpleMessage() async throws {
    let client = SwiftAeronClient(host: "127.0.0.1", port: 40001)
    
    try await client.connect()
    
    let message = "Hello from Swift!".data(using: .utf8)!
    try await client.sendData(message, sessionId: 1, streamId: 1001)
    
    client.disconnect()
}
```

### Simple Message Receiving

```swift
import SwiftAeronClient

func receiveMessages() async throws {
    let receiver = try SwiftAeronReceiver(port: 40001)
    
    receiver.onDataReceived = { data, sessionId, streamId in
        let message = String(data: data, encoding: .utf8) ?? "Invalid UTF-8"
        print("Received: \(message)")
    }
    
    try await receiver.startListening()
    
    // Keep listening for 30 seconds
    try await Task.sleep(nanoseconds: 30_000_000_000)
    
    receiver.stopListening()
}
```

## Reliable Communication Examples

### Reliable File Transfer

```swift
import SwiftAeronClient
import Foundation

class FileTransferClient {
    private let client: ReliableAeronClient
    
    init(host: String, port: UInt16) {
        self.client = ReliableAeronClient(host: host, port: port)
    }
    
    func transferFile(at url: URL, sessionId: UInt32 = 1, streamId: UInt32 = 1001) async throws {
        try await client.connect()
        
        let fileData = try Data(contentsOf: url)
        let chunkSize = 64 * 1024 // 64KB chunks
        
        print("Transferring file: \(url.lastPathComponent)")
        print("Size: \(fileData.count) bytes")
        print("Chunks: \(Int(ceil(Double(fileData.count) / Double(chunkSize))))")
        
        var offset = 0
        var chunkIndex = 0
        
        while offset < fileData.count {
            let remainingBytes = fileData.count - offset
            let currentChunkSize = min(chunkSize, remainingBytes)
            
            let chunk = fileData.subdata(in: offset..<offset + currentChunkSize)
            
            // Add metadata header to chunk
            var chunkWithHeader = Data()
            chunkWithHeader.append(withUnsafeBytes(of: UInt32(chunkIndex).littleEndian) { Data($0) })
            chunkWithHeader.append(withUnsafeBytes(of: UInt32(fileData.count).littleEndian) { Data($0) })
            chunkWithHeader.append(chunk)
            
            try await client.sendReliable(chunkWithHeader, sessionId: sessionId, streamId: streamId)
            
            offset += currentChunkSize
            chunkIndex += 1
            
            if chunkIndex % 10 == 0 {
                print("Sent chunk \(chunkIndex)")
            }
        }
        
        print("File transfer completed!")
        client.disconnect()
    }
}

// Usage
let transferClient = FileTransferClient(host: "192.168.1.100", port: 40001)
try await transferClient.transferFile(at: URL(fileURLWithPath: "/path/to/file.txt"))
```

### Reliable File Receiver

```swift
import SwiftAeronClient
import Foundation

class FileTransferReceiver {
    private let receiver: ReliableAeronReceiver
    private var receivedChunks: [UInt32: Data] = [:]
    private var expectedFileSize: UInt32 = 0
    private var currentFile: URL?
    
    init(port: UInt16) throws {
        self.receiver = try ReliableAeronReceiver(port: port)
        setupHandlers()
    }
    
    private func setupHandlers() {
        receiver.onDataReceived = { [weak self] data, sequenceNumber, sessionId, streamId in
            self?.handleFileChunk(data, sequenceNumber: sequenceNumber)
        }
    }
    
    private func handleFileChunk(_ data: Data, sequenceNumber: UInt32) {
        guard data.count >= 8 else {
            print("Invalid chunk: too small")
            return
        }
        
        let chunkIndex = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let fileSize = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.littleEndian
        let chunkData = data.subdata(in: 8..<data.count)
        
        if expectedFileSize == 0 {
            expectedFileSize = fileSize
            currentFile = createTempFile()
            print("Starting file reception: \(fileSize) bytes expected")
        }
        
        receivedChunks[chunkIndex] = chunkData
        
        if chunkIndex % 10 == 0 {
            print("Received chunk \(chunkIndex)")
        }
        
        // Check if file is complete
        checkFileComplete()
    }
    
    private func checkFileComplete() {
        let totalReceivedBytes = receivedChunks.values.reduce(0) { $0 + $1.count }
        
        if totalReceivedBytes >= expectedFileSize {
            assembleFile()
        }
    }
    
    private func assembleFile() {
        guard let fileURL = currentFile else { return }
        
        let sortedChunks = receivedChunks.sorted { $0.key < $1.key }
        var completeData = Data()
        
        for (_, chunkData) in sortedChunks {
            completeData.append(chunkData)
        }
        
        do {
            try completeData.write(to: fileURL)
            print("File received successfully: \(fileURL.path)")
            print("Final size: \(completeData.count) bytes")
        } catch {
            print("Failed to write file: \(error)")
        }
        
        // Reset for next file
        receivedChunks.removeAll()
        expectedFileSize = 0
        currentFile = nil
    }
    
    private func createTempFile() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "received_file_\(Date().timeIntervalSince1970).dat"
        return tempDir.appendingPathComponent(fileName)
    }
    
    func startReceiving() async throws {
        try await receiver.startListening()
        print("File receiver started on port \(receiver)")
    }
    
    func stopReceiving() {
        receiver.stopListening()
    }
}

// Usage
let fileReceiver = try FileTransferReceiver(port: 40001)
try await fileReceiver.startReceiving()
```

## Chat Application Example

### Chat Client

```swift
import SwiftAeronClient

struct ChatMessage: Codable {
    let timestamp: Date
    let username: String
    let message: String
    let messageId: UUID
}

class ChatClient {
    private let client: ReliableAeronClient
    private let receiver: ReliableAeronReceiver
    private let username: String
    
    var onMessageReceived: ((ChatMessage) -> Void)?
    
    init(username: String, serverHost: String, serverPort: UInt16, clientPort: UInt16) throws {
        self.username = username
        self.client = ReliableAeronClient(host: serverHost, port: serverPort)
        self.receiver = try ReliableAeronReceiver(port: clientPort)
        
        setupReceiver()
    }
    
    private func setupReceiver() {
        receiver.onDataReceived = { [weak self] data, sequenceNumber, sessionId, streamId in
            self?.handleIncomingMessage(data)
        }
    }
    
    private func handleIncomingMessage(_ data: Data) {
        do {
            let chatMessage = try JSONDecoder().decode(ChatMessage.self, from: data)
            onMessageReceived?(chatMessage)
        } catch {
            print("Failed to decode chat message: \(error)")
        }
    }
    
    func connect() async throws {
        try await client.connect()
        try await receiver.startListening()
        
        // Send join message
        try await sendMessage("joined the chat", isSystem: true)
    }
    
    func sendMessage(_ message: String, isSystem: Bool = false) async throws {
        let chatMessage = ChatMessage(
            timestamp: Date(),
            username: isSystem ? "System" : username,
            message: message,
            messageId: UUID()
        )
        
        let messageData = try JSONEncoder().encode(chatMessage)
        try await client.sendReliable(messageData, sessionId: 1, streamId: 2001)
    }
    
    func disconnect() {
        Task {
            try? await sendMessage("left the chat", isSystem: true)
        }
        client.disconnect()
        receiver.stopListening()
    }
}

// Usage
let chatClient = try ChatClient(
    username: "Alice",
    serverHost: "192.168.1.100",
    serverPort: 40001,
    clientPort: 40002
)

chatClient.onMessageReceived = { message in
    print("[\(message.timestamp)] \(message.username): \(message.message)")
}

try await chatClient.connect()
try await chatClient.sendMessage("Hello everyone!")
```

## Performance Testing Example

```swift
import SwiftAeronClient

class AeronPerformanceBenchmark {
    let host: String
    let port: UInt16
    
    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
    
    func runThroughputTest(messageSize: Int, messageCount: Int) async throws {
        let client = ReliableAeronClient(host: host, port: port)
        
        try await client.connect()
        
        let testData = Data(repeating: 0xAB, count: messageSize)
        let startTime = Date()
        
        print("Starting throughput test...")
        print("Message size: \(messageSize) bytes")
        print("Message count: \(messageCount)")
        
        for i in 0..<messageCount {
            try await client.sendReliable(testData, sessionId: 1, streamId: 3001)
            
            if i % 100 == 0 {
                let progress = Double(i) / Double(messageCount) * 100
                print("Progress: \(String(format: "%.1f", progress))%")
            }
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        let totalBytes = messageSize * messageCount
        let throughputMBps = Double(totalBytes) / 1024.0 / 1024.0 / duration
        let messagesPerSecond = Double(messageCount) / duration
        
        print("\n=== Performance Results ===")
        print("Duration: \(String(format: "%.2f", duration))s")
        print("Total data: \(String(format: "%.2f", Double(totalBytes) / 1024.0 / 1024.0)) MB")
        print("Throughput: \(String(format: "%.2f", throughputMBps)) MB/s")
        print("Messages/sec: \(String(format: "%.2f", messagesPerSecond))")
        
        // Get reliability statistics
        let stats = client.getStatistics()
        stats.printStatistics()
        
        client.disconnect()
    }
    
    func runLatencyTest(messageCount: Int) async throws {
        let client = ReliableAeronClient(host: host, port: port)
        try await client.connect()
        
        var latencies: [TimeInterval] = []
        let testData = "ping".data(using: .utf8)!
        
        print("Starting latency test with \(messageCount) ping messages...")
        
        for i in 0..<messageCount {
            let sendTime = Date()
            try await client.sendReliable(testData, sessionId: 1, streamId: 4001)
            
            // In a real test, you'd wait for a response and measure round-trip time
            // For this example, we'll simulate the send latency
            let latency = Date().timeIntervalSince(sendTime)
            latencies.append(latency)
            
            if i % 10 == 0 {
                print("Ping \(i + 1)/\(messageCount)")
            }
        }
        
        let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
        let minLatency = latencies.min() ?? 0
        let maxLatency = latencies.max() ?? 0
        
        print("\n=== Latency Results ===")
        print("Average: \(String(format: "%.3f", avgLatency * 1000))ms")
        print("Minimum: \(String(format: "%.3f", minLatency * 1000))ms")
        print("Maximum: \(String(format: "%.3f", maxLatency * 1000))ms")
        
        client.disconnect()
    }
}

// Usage
let benchmark = AeronPerformanceBenchmark(host: "127.0.0.1", port: 40001)

// Test throughput with 1KB messages
try await benchmark.runThroughputTest(messageSize: 1024, messageCount: 1000)

// Test latency
try await benchmark.runLatencyTest(messageCount: 100)
```

## Error Handling Example

```swift
import SwiftAeronClient

func robustAeronCommunication() async {
    let client = ReliableAeronClient(host: "192.168.1.100", port: 40001)
    
    do {
        try await client.connect()
        print("Connected successfully")
        
        let message = "Important data".data(using: .utf8)!
        
        // Retry mechanism for critical messages
        var retryCount = 0
        let maxRetries = 3
        
        while retryCount < maxRetries {
            do {
                try await client.sendReliable(message, sessionId: 1, streamId: 1001)
                print("Message sent successfully")
                break
            } catch {
                retryCount += 1
                print("Send failed (attempt \(retryCount)/\(maxRetries)): \(error)")
                
                if retryCount < maxRetries {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                } else {
                    print("Failed to send after \(maxRetries) attempts")
                    throw error
                }
            }
        }
        
    } catch AeronError.notConnected {
        print("Failed to connect - check network and server")
    } catch AeronError.connectionCancelled {
        print("Connection was cancelled")
    } catch {
        print("Unexpected error: \(error)")
    }
    
    client.disconnect()
}
```

---

⚠️ **Note**: All examples are AI-generated and should be thoroughly tested and reviewed before production use. Pay special attention to error handling, resource management, and security implications in your specific environment.