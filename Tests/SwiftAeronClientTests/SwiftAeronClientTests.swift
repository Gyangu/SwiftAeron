import XCTest
@testable import SwiftAeronClient

final class SwiftAeronClientTests: XCTestCase {
    func testAeronFrameCreation() throws {
        let client = SwiftAeronClient(host: "127.0.0.1", port: 40001)
        // Basic test to ensure the client can be created
        XCTAssertNotNil(client)
    }
}