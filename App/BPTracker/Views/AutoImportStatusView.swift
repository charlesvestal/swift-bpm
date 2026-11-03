import SwiftUI

/// One line in the sidebar saying what the BPM25 auto-import is doing.
struct AutoImportStatusView: View {
    @Environment(BPM25AutoImporter.self) private var autoImporter

    var body: some View {
        switch autoImporter.status {
        case .disabled, .notConnected:
            EmptyView()
        case .waiting:
            line("BPM25 connected. Switch it to PC mode.", systemImage: "cable.connector")
        case .importing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Importing from BPM25…")
            }
            .font(.caption)
        case let .imported(summary, date):
            line(summary.added == 0 ? "BPM25 up to date, \(date.formatted(date: .omitted, time: .shortened))"
                                    : "BPM25: \(summary.message) \(date.formatted(date: .omitted, time: .shortened))",
                 systemImage: "checkmark.circle")
        case let .failed(message):
            line(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func line(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
