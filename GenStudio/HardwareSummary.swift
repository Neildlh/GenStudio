import Foundation

/// The rows the sidebar shows for the Mac GenStudio is running on. Pure formatting over a
/// `HardwareProfile`: a value the system did not report is omitted, never shown as zero.
struct HardwareSummary: Equatable, Sendable {
    let chip: String
    let cores: String?
    let memory: String?
    let modelBudget: String?
    let disk: String?
    /// Share of the library drive already in use, for a usage bar. Nil when capacity is unknown.
    let diskUsedFraction: Double?
    let system: String

    init(_ hardware: HardwareProfile) {
        chip = hardware.chip

        var parts: [String] = []
        let cpu = hardware.performanceCores + hardware.efficiencyCores
        if cpu > 0 {
            parts.append(hardware.performanceCores > 0 && hardware.efficiencyCores > 0
                ? "\(cpu) CPU cores (\(hardware.performanceCores) performance + \(hardware.efficiencyCores) efficiency)"
                : "\(cpu) CPU cores")
        }
        if hardware.gpuCores > 0 { parts.append("\(hardware.gpuCores) GPU cores") }
        cores = parts.isEmpty ? nil : parts.joined(separator: " · ")

        if hardware.memoryBytes > 0 {
            memory = "\(Self.gigabytes(hardware.memoryBytes)) GB unified memory"
            modelBudget = "Models can use about \(Self.gigabytes(hardware.usableModelBytes)) GB · comfortable up to \(Self.gigabytes(hardware.comfortableModelBytes)) GB"
        } else {
            memory = nil
            modelBudget = nil
        }

        if hardware.freeDiskBytes > 0, hardware.totalDiskBytes > 0 {
            disk = "\(ModelLibraryViewModel.bytes(hardware.freeDiskBytes)) free of \(ModelLibraryViewModel.bytes(hardware.totalDiskBytes))"
            diskUsedFraction = min(1, max(0, Double(hardware.totalDiskBytes - hardware.freeDiskBytes) / Double(hardware.totalDiskBytes)))
        } else if hardware.freeDiskBytes > 0 {
            disk = "\(ModelLibraryViewModel.bytes(hardware.freeDiskBytes)) free"
            diskUsedFraction = nil
        } else {
            disk = nil
            diskUsedFraction = nil
        }

        system = "macOS " + Self.version(from: hardware.osVersion)
    }

    /// Memory is sold and reported in binary gigabytes, so 64 GiB reads as "64 GB".
    private static func gigabytes(_ bytes: UInt64) -> Int { Int((Double(bytes) / 1_073_741_824).rounded()) }

    /// "Version 27.0 (Build 27A5001a)" → "27.0". Anything unrecognised is passed through unchanged.
    private static func version(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"^(?:Version |macOS )?\d+(?:\.\d+)*"#, options: .regularExpression) else { return trimmed }
        return String(trimmed[range]).replacingOccurrences(of: "Version ", with: "").replacingOccurrences(of: "macOS ", with: "")
    }
}
