import XCTest
@testable import CommandCenterCore

final class SystemMetricsTests: XCTestCase {
    func testDarwinMetricsReturnPlausibleNativeSnapshot() throws {
        let snapshot = try DarwinSystemMetrics().snapshot()

        XCTAssertGreaterThan(snapshot.physicalBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.availableBytes, snapshot.physicalBytes)
        XCTAssertGreaterThan(snapshot.appResidentBytes, 0)
    }
}
