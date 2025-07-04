import Foundation

// MARK: - Aeron Protocol Specification Constants

/// Aeron Protocol Specification - 严格按照官方规范
public struct AeronProtocolSpec {
    
    // MARK: - Frame Types (按照Aeron官方定义)
    
    public static let DATA_HEADER_TYPE: UInt16 = 0x01
    public static let PAD_HEADER_TYPE: UInt16 = 0x02
    public static let SM_HEADER_TYPE: UInt16 = 0x03         // Status Message
    public static let NAK_HEADER_TYPE: UInt16 = 0x04
    public static let SETUP_HEADER_TYPE: UInt16 = 0x05
    public static let RTT_MEASUREMENT_HEADER_TYPE: UInt16 = 0x06
    public static let RESOLUTION_HEADER_TYPE: UInt16 = 0x07
    
    // MARK: - Header Lengths
    
    public static let DATA_HEADER_LENGTH: Int = 32
    public static let SETUP_HEADER_LENGTH: Int = 40
    public static let STATUS_MESSAGE_HEADER_LENGTH: Int = 28
    public static let NAK_HEADER_LENGTH: Int = 28
    public static let RTT_MEASUREMENT_HEADER_LENGTH: Int = 32
    
    // MARK: - Frame Flags
    
    public static let BEGIN_FLAG: UInt8 = 0x80
    public static let END_FLAG: UInt8 = 0x40
    public static let UNFRAGMENTED: UInt8 = BEGIN_FLAG | END_FLAG
    
    // MARK: - Default Values
    
    public static let PROTOCOL_VERSION: UInt8 = 0x01
    public static let HDR_TYPE_PAD: UInt8 = 0x00
    public static let HDR_TYPE_DATA: UInt8 = 0x01
    
    // MARK: - Alignment
    
    public static let FRAME_ALIGNMENT: Int = 32
    public static let CACHE_LINE_SIZE: Int = 64
    
    // MARK: - Term Buffer Configuration
    
    public static let TERM_MIN_LENGTH: Int = 64 * 1024      // 64KB
    public static let TERM_MAX_LENGTH: Int = 1024 * 1024 * 1024 // 1GB
    public static let TERM_DEFAULT_LENGTH: Int = 16 * 1024 * 1024 // 16MB
    
    // MARK: - Page Size
    
    public static let PAGE_MIN_SIZE: Int = 4 * 1024         // 4KB
    public static let PAGE_MAX_SIZE: Int = 1024 * 1024 * 1024 // 1GB
    
    // MARK: - MTU
    
    public static let MTU_LENGTH_DEFAULT: Int = 1408        // Aeron默认MTU
    public static let MAX_UDP_PAYLOAD_LENGTH: Int = 65507
    
    // MARK: - Session and Stream Configuration
    
    public static let PUBLICATION_LINGER_TIMEOUT_MS: Int64 = 5000
    public static let CLIENT_LINGER_TIMEOUT_MS: Int64 = 5000
    
    // MARK: - Position Encoding
    
    public static func computePosition(termId: Int32, termOffset: Int32, positionBitsToShift: Int) -> Int64 {
        return (Int64(termId) << positionBitsToShift) + Int64(termOffset)
    }
    
    public static func computeTermIdFromPosition(position: Int64, positionBitsToShift: Int) -> Int32 {
        return Int32(position >> positionBitsToShift)
    }
    
    public static func computeTermOffsetFromPosition(position: Int64, positionBitsToShift: Int) -> Int32 {
        let termLength = Int64(1 << positionBitsToShift)
        return Int32(position & (termLength - 1))
    }
    
    public static func positionBitsToShift(termBufferLength: Int) -> Int {
        return Int(log2(Double(termBufferLength)))
    }
}

// MARK: - Aeron Data Header (按照官方C++/Java实现)

public struct AeronDataHeader {
    public let frameLength: UInt32      // 0-3: Frame length including header
    public let version: UInt8           // 4: Version
    public let flags: UInt8             // 5: Flags (BEGIN_FLAG | END_FLAG)
    public let type: UInt16             // 6-7: Frame type
    public let termOffset: UInt32       // 8-11: Offset within term
    public let sessionId: UInt32        // 12-15: Session ID  
    public let streamId: UInt32         // 16-19: Stream ID
    public let termId: UInt32           // 20-23: Term ID
    public let reservedValue: UInt64    // 24-31: Reserved for future use
    
    public init(frameLength: UInt32, termOffset: UInt32, sessionId: UInt32, streamId: UInt32, termId: UInt32) {
        self.frameLength = frameLength
        self.version = AeronProtocolSpec.PROTOCOL_VERSION
        self.flags = AeronProtocolSpec.UNFRAGMENTED
        self.type = AeronProtocolSpec.DATA_HEADER_TYPE
        self.termOffset = termOffset
        self.sessionId = sessionId
        self.streamId = streamId
        self.termId = termId
        self.reservedValue = 0
    }
    
    public func toBytes() -> Data {
        var data = Data(capacity: AeronProtocolSpec.DATA_HEADER_LENGTH)
        
        // Little-endian encoding (按照Aeron规范)
        data.append(contentsOf: frameLength.littleEndian.bytes)
        data.append(version)
        data.append(flags)
        data.append(contentsOf: type.littleEndian.bytes)
        data.append(contentsOf: termOffset.littleEndian.bytes)
        data.append(contentsOf: sessionId.littleEndian.bytes)
        data.append(contentsOf: streamId.littleEndian.bytes)
        data.append(contentsOf: termId.littleEndian.bytes)
        data.append(contentsOf: reservedValue.littleEndian.bytes)
        
        return data
    }
    
    public static func fromBytes(_ data: Data) -> AeronDataHeader? {
        guard data.count >= AeronProtocolSpec.DATA_HEADER_LENGTH else { return nil }
        
        let frameLength = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let version = data[4]
        let flags = data[5]
        let type = data.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }.littleEndian
        let termOffset = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }.littleEndian
        let sessionId = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }.littleEndian
        let streamId = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }.littleEndian
        let termId = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }.littleEndian
        let reservedValue = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }.littleEndian
        
        return AeronDataHeader(
            frameLength: frameLength,
            termOffset: termOffset,
            sessionId: sessionId,
            streamId: streamId,
            termId: termId
        )
    }
}

// MARK: - Aeron Setup Header

public struct AeronSetupHeader {
    public let frameLength: UInt32      // 0-3
    public let version: UInt8           // 4
    public let flags: UInt8             // 5
    public let type: UInt16             // 6-7
    public let termOffset: UInt32       // 8-11
    public let sessionId: UInt32        // 12-15
    public let streamId: UInt32         // 16-19
    public let initialTermId: UInt32    // 20-23
    public let activeTermId: UInt32     // 24-27
    public let termLength: UInt32       // 28-31
    public let mtuLength: UInt32        // 32-35
    public let ttl: UInt32              // 36-39
    
    public init(sessionId: UInt32, streamId: UInt32, initialTermId: UInt32, termLength: UInt32, mtuLength: UInt32 = UInt32(AeronProtocolSpec.MTU_LENGTH_DEFAULT)) {
        self.frameLength = UInt32(AeronProtocolSpec.SETUP_HEADER_LENGTH)
        self.version = AeronProtocolSpec.PROTOCOL_VERSION
        self.flags = 0
        self.type = AeronProtocolSpec.SETUP_HEADER_TYPE
        self.termOffset = 0
        self.sessionId = sessionId
        self.streamId = streamId
        self.initialTermId = initialTermId
        self.activeTermId = initialTermId
        self.termLength = termLength
        self.mtuLength = mtuLength
        self.ttl = 0
    }
    
    public func toBytes() -> Data {
        var data = Data(capacity: AeronProtocolSpec.SETUP_HEADER_LENGTH)
        
        data.append(contentsOf: frameLength.littleEndian.bytes)
        data.append(version)
        data.append(flags)
        data.append(contentsOf: type.littleEndian.bytes)
        data.append(contentsOf: termOffset.littleEndian.bytes)
        data.append(contentsOf: sessionId.littleEndian.bytes)
        data.append(contentsOf: streamId.littleEndian.bytes)
        data.append(contentsOf: initialTermId.littleEndian.bytes)
        data.append(contentsOf: activeTermId.littleEndian.bytes)
        data.append(contentsOf: termLength.littleEndian.bytes)
        data.append(contentsOf: mtuLength.littleEndian.bytes)
        data.append(contentsOf: ttl.littleEndian.bytes)
        
        return data
    }
}

// MARK: - Status Message Header

public struct AeronStatusMessageHeader {
    public let frameLength: UInt32      // 0-3
    public let version: UInt8           // 4
    public let flags: UInt8             // 5
    public let type: UInt16             // 6-7
    public let sessionId: UInt32        // 8-11
    public let streamId: UInt32         // 12-15
    public let consumptionTermId: UInt32 // 16-19
    public let consumptionTermOffset: UInt32 // 20-23
    public let receiverWindowLength: UInt32 // 24-27
    
    public init(sessionId: UInt32, streamId: UInt32, termId: UInt32, termOffset: UInt32, receiverWindow: UInt32) {
        self.frameLength = UInt32(AeronProtocolSpec.STATUS_MESSAGE_HEADER_LENGTH)
        self.version = AeronProtocolSpec.PROTOCOL_VERSION
        self.flags = 0
        self.type = AeronProtocolSpec.SM_HEADER_TYPE
        self.sessionId = sessionId
        self.streamId = streamId
        self.consumptionTermId = termId
        self.consumptionTermOffset = termOffset
        self.receiverWindowLength = receiverWindow
    }
    
    public func toBytes() -> Data {
        var data = Data(capacity: AeronProtocolSpec.STATUS_MESSAGE_HEADER_LENGTH)
        
        data.append(contentsOf: frameLength.littleEndian.bytes)
        data.append(version)
        data.append(flags)
        data.append(contentsOf: type.littleEndian.bytes)
        data.append(contentsOf: sessionId.littleEndian.bytes)
        data.append(contentsOf: streamId.littleEndian.bytes)
        data.append(contentsOf: consumptionTermId.littleEndian.bytes)
        data.append(contentsOf: consumptionTermOffset.littleEndian.bytes)
        data.append(contentsOf: receiverWindowLength.littleEndian.bytes)
        
        return data
    }
}

// MARK: - Utility Extensions

extension FixedWidthInteger {
    public var bytes: [UInt8] {
        withUnsafeBytes(of: self) { Array($0) }
    }
}

extension UInt32 {
    static func fromLittleEndianBytes(_ bytes: Data, offset: Int) -> UInt32 {
        return bytes.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }
}

extension UInt16 {
    static func fromLittleEndianBytes(_ bytes: Data, offset: Int) -> UInt16 {
        return bytes.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self) }.littleEndian
    }
}