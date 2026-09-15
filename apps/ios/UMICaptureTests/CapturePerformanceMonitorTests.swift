import XCTest
@testable import UMICapture

final class CapturePerformanceMonitorTests: XCTestCase {
    func testLoadLevelUsesWorstOfFootprintAndHeadroom() {
        XCTAssertEqual(
            CapturePerformanceMonitor.memoryLoadLevel(
                physicalMemoryMB: 850,
                availableMemoryMB: 1_500
            ),
            .normal
        )
        XCTAssertEqual(
            CapturePerformanceMonitor.memoryLoadLevel(
                physicalMemoryMB: 850,
                availableMemoryMB: 700
            ),
            .high
        )
        XCTAssertEqual(
            CapturePerformanceMonitor.memoryLoadLevel(
                physicalMemoryMB: 1_700,
                availableMemoryMB: 1_500
            ),
            .critical
        )
    }

    func testSafeGrowthBudgetReservesSevenHundredMegabytes() {
        XCTAssertEqual(
            CapturePerformanceMonitor.safeGrowthBudget(
                availableMemoryMB: 1_100
            ),
            400
        )
        XCTAssertEqual(
            CapturePerformanceMonitor.safeGrowthBudget(
                availableMemoryMB: 500
            ),
            0
        )
    }
}
