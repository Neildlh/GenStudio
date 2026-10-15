import XCTest
@testable import GenStudio

final class HardwareSummaryTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024

    /// The reference machine: M1 Max, 64 GB, 10-core CPU (8P + 2E), 32-core GPU.
    private func m1Max() -> HardwareProfile {
        HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 * gib, osVersion: "Version 27.0 (Build 27A5001a)",
                        freeDiskBytes: 212_000_000_000, totalDiskBytes: 994_000_000_000,
                        gpuWorkingSetBytes: 48 * gib, performanceCores: 8, efficiencyCores: 2, gpuCores: 32)
    }

    func testChipIsShownVerbatim() {
        XCTAssertEqual(HardwareSummary(m1Max()).chip, "Apple M1 Max")
    }

    func testCoreLineNamesPerformanceAndEfficiencySplitAndGPU() {
        XCTAssertEqual(HardwareSummary(m1Max()).cores, "10 CPU cores (8 performance + 2 efficiency) · 32 GPU cores")
    }

    func testCoreLineOmitsTheGPUWhenItsCountIsUnknown() {
        var hardware = m1Max(); hardware.gpuCores = 0
        XCTAssertEqual(HardwareSummary(hardware).cores, "10 CPU cores (8 performance + 2 efficiency)")
    }

    func testCoreLineIsOmittedRatherThanShownAsZero() {
        var hardware = m1Max(); hardware.performanceCores = 0; hardware.efficiencyCores = 0; hardware.gpuCores = 0
        XCTAssertNil(HardwareSummary(hardware).cores)
    }

    func testCoreLineHandlesAChipWithNoEfficiencyCores() {
        var hardware = m1Max(); hardware.efficiencyCores = 0
        XCTAssertEqual(HardwareSummary(hardware).cores, "8 CPU cores · 32 GPU cores")
    }

    func testMemoryIsReportedInWholeGigabytesOfUnifiedMemory() {
        XCTAssertEqual(HardwareSummary(m1Max()).memory, "64 GB unified memory")
    }

    func testUnknownMemoryIsOmitted() {
        var hardware = m1Max(); hardware = HardwareProfile(chip: hardware.chip, memoryBytes: 0, osVersion: hardware.osVersion, freeDiskBytes: hardware.freeDiskBytes)
        XCTAssertNil(HardwareSummary(hardware).memory)
        XCTAssertNil(HardwareSummary(hardware).modelBudget)
    }

    func testModelBudgetUsesMetalWorkingSetAndHalfOfMemoryForComfort() {
        XCTAssertEqual(HardwareSummary(m1Max()).modelBudget, "Models can use about 48 GB · comfortable up to 32 GB")
    }

    func testModelBudgetFallsBackToThreeQuartersOfMemoryWhenMetalReportsNothing() {
        var hardware = m1Max(); hardware.gpuWorkingSetBytes = 0
        XCTAssertEqual(hardware.usableModelBytes, 48 * gib)
        XCTAssertEqual(HardwareSummary(hardware).modelBudget, "Models can use about 48 GB · comfortable up to 32 GB")
    }

    func testComfortableThresholdMatchesTheExistingDemandingRule() {
        // ModelCompatibility marks a package demanding when memory / 2 < its requirement.
        XCTAssertEqual(m1Max().comfortableModelBytes, m1Max().memoryBytes / 2)
    }

    func testDiskLineShowsFreeOfTotalAndUsedFraction() throws {
        let summary = HardwareSummary(m1Max())
        XCTAssertEqual(summary.disk, "\(ModelLibraryViewModel.bytes(212_000_000_000)) free of \(ModelLibraryViewModel.bytes(994_000_000_000))")
        let fraction = try XCTUnwrap(summary.diskUsedFraction)
        XCTAssertEqual(fraction, 782.0 / 994.0, accuracy: 0.0001)
    }

    func testDiskLineFallsBackToFreeSpaceOnlyWhenCapacityIsUnknown() {
        var hardware = m1Max(); hardware.totalDiskBytes = 0
        let summary = HardwareSummary(hardware)
        XCTAssertEqual(summary.disk, "\(ModelLibraryViewModel.bytes(212_000_000_000)) free")
        XCTAssertNil(summary.diskUsedFraction)
    }

    func testMacOSVersionIsExtractedFromTheVerboseSystemString() {
        XCTAssertEqual(HardwareSummary(m1Max()).system, "macOS 27.0")
    }

    func testMacOSVersionAcceptsAPlainVersionNumber() {
        var hardware = m1Max(); hardware = HardwareProfile(chip: hardware.chip, memoryBytes: hardware.memoryBytes, osVersion: "26.4.1", freeDiskBytes: 1)
        XCTAssertEqual(HardwareSummary(hardware).system, "macOS 26.4.1")
    }

    func testUnrecognisedOSStringIsShownRatherThanInvented() {
        var hardware = m1Max(); hardware = HardwareProfile(chip: hardware.chip, memoryBytes: hardware.memoryBytes, osVersion: "Sequoia-ish", freeDiskBytes: 1)
        XCTAssertEqual(HardwareSummary(hardware).system, "macOS Sequoia-ish")
    }
}
