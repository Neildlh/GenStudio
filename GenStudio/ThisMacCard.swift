import SwiftUI

/// The Mac GenStudio is running on, shown above Model Storage in the Models sidebar.
struct ThisMacCard: View {
    @ObservedObject var store: ModelLibraryViewModel

    var body: some View {
        if let hardware = store.hardware {
            let summary = HardwareSummary(hardware)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "cpu.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.chip).font(.headline)
                        if let cores = summary.cores {
                            Text(cores).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let memory = summary.memory {
                    detail(icon: "memorychip", title: memory, subtitle: summary.modelBudget)
                }
                if let disk = summary.disk {
                    VStack(alignment: .leading, spacing: 4) {
                        detail(icon: "internaldrive", title: disk, subtitle: nil)
                        if let used = summary.diskUsedFraction {
                            StudioLinearProgress(value: used)
                                .padding(.leading, 30)
                                .accessibilityLabel("Drive used").accessibilityValue("\(Int((used * 100).rounded())) percent")
                        }
                    }
                }
                Text(summary.system).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, Space.xs)
            .accessibilityElement(children: .contain)
        } else {
            Text("Reading this Mac…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(icon: String, title: String, subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
