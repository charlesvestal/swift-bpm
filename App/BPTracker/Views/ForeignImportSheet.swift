import BPMKit
import SwiftData
import SwiftUI

/// Imports another app's CSV export by column position, with presets for
/// common vendor apps and a live preview of what will be read.
struct ForeignImportSheet: View {
    let fileName: String
    let text: String
    let initialProfile: Profile?
    let onImported: (ImportSummary) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]

    @State private var mapping = ColumnMapping.custom
    @State private var profile: Profile?
    @State private var error: String?

    private var result: Result<ColumnMapping.Result, Error> {
        Result { try mapping.decode(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(fileName)").font(.title2.bold())
            HStack(alignment: .top, spacing: 16) {
                Form {
                    Picker("Format", selection: Binding(get: { mapping.name }, set: { name in
                        mapping = (ColumnMapping.presets + [.custom]).first { $0.name == name } ?? .custom
                    })) {
                        ForEach(ColumnMapping.presets) { Text($0.name).tag($0.name) }
                        Divider()
                        Text("Custom").tag(ColumnMapping.custom.name)
                    }
                    Picker("Profile", selection: $profile) {
                        ForEach(profiles) { Text($0.name).tag(Optional($0)) }
                    }
                    Section("Layout") {
                        TextField("Delimiter", text: $mapping.delimiter)
                        TextField("First data line", value: $mapping.firstDataLine, format: .number)
                        TextField("Date column", value: column(\.dateColumn), format: .number)
                        TextField("Date format", text: $mapping.dateFormat)
                        TextField("Time column", value: optionalColumn(\.timeColumn), format: .number, prompt: Text("in date column"))
                        TextField("Time format", text: $mapping.timeFormat)
                            .disabled(mapping.timeColumn == nil)
                    }
                    Section("Columns") {
                        TextField("Systolic", value: column(\.systolicColumn), format: .number)
                        TextField("Diastolic", value: column(\.diastolicColumn), format: .number)
                        TextField("Pulse", value: optionalColumn(\.pulseColumn), format: .number, prompt: Text("none"))
                        TextField("Irregular heartbeat", value: optionalColumn(\.irregularColumn), format: .number, prompt: Text("none"))
                        TextField("…when value is", text: $mapping.irregularValues, prompt: Text("Yes|Detected"))
                        TextField("Body movement", value: optionalColumn(\.movementColumn), format: .number, prompt: Text("none"))
                        TextField("…when value is", text: $mapping.movementValues, prompt: Text("Yes|Detected"))
                        TextField("Note", value: optionalColumn(\.noteColumn), format: .number, prompt: Text("none"))
                    }
                }
                .formStyle(.grouped)
                .frame(width: 330)

                VStack(alignment: .leading, spacing: 10) {
                    Text("File").font(.headline)
                    ScrollView([.horizontal, .vertical]) {
                        Text(filePreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                    Text("Readings found").font(.headline)
                    preview
                }
                .frame(minWidth: 360)
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Text("Column numbers start at 1. Date formats use Unicode patterns, such as d.M.yyyy or h:mm a.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { importRows() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(((try? result.get())?.rows.isEmpty ?? true) || profile == nil)
            }
        }
        .padding(20)
        .frame(width: 780, height: 620)
        .onAppear {
            mapping = ColumnMapping.guess(fileName: fileName) ?? .custom
            profile = initialProfile ?? profiles.first
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch result {
        case let .success(r):
            Text("\(r.rows.count) readings" + (r.skippedLines.isEmpty ? "" : ", \(r.skippedLines.count) lines skipped (\(r.skippedLines.prefix(5).map(String.init).joined(separator: ", "))\(r.skippedLines.count > 5 ? "…" : ""))"))
                .font(.callout)
                .foregroundStyle(r.rows.isEmpty ? .orange : .secondary)
            List(Array(r.rows.prefix(50).enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.timestamp, format: .dateTime.year().month().day().hour().minute())
                    Spacer()
                    Text("\(row.systolic)/\(row.diastolic)").monospacedDigit()
                    Text(row.pulse.map { "\($0)" } ?? "–").monospacedDigit().frame(width: 30, alignment: .trailing)
                    if row.irregularHeartbeat { Image(systemName: "heart.fill").foregroundStyle(.red) }
                }
                .font(.callout)
            }
            .listStyle(.bordered)
        case let .failure(e):
            Text(e.localizedDescription).foregroundStyle(.orange)
            Spacer()
        }
    }

    /// The lines around the first data line, with column numbers on the first data row.
    private var filePreview: String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let start = max(0, mapping.firstDataLine - 3)
        var out = lines[start..<min(lines.count, start + 8)].enumerated().map { offset, line in
            String(format: "%3d  ", start + offset + 1) + line
        }
        if mapping.firstDataLine - 1 < lines.count, let delimiter = mapping.delimiter.first {
            let fields = lines[mapping.firstDataLine - 1].split(separator: delimiter, omittingEmptySubsequences: false)
            out.append("")
            out.append("Line \(mapping.firstDataLine) by column:")
            out += fields.enumerated().map { "  \($0.offset + 1): \($0.element)" }
        }
        return out.joined(separator: "\n")
    }

    /// Shows 0-based columns as 1-based.
    private func column(_ keyPath: WritableKeyPath<ColumnMapping, Int>) -> Binding<Int> {
        Binding(get: { mapping[keyPath: keyPath] + 1 }, set: { mapping[keyPath: keyPath] = max(0, $0 - 1) })
    }

    private func optionalColumn(_ keyPath: WritableKeyPath<ColumnMapping, Int?>) -> Binding<Int?> {
        Binding(get: { mapping[keyPath: keyPath].map { $0 + 1 } },
                set: { mapping[keyPath: keyPath] = $0.map { max(0, $0 - 1) } })
    }

    private func importRows() {
        guard let profile, case let .success(r) = result else { return }
        do {
            let summary = try ReadingImporter(context: context).importCSV(r.rows, fallbackProfile: profile)
            onImported(summary)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension String {
    /// Vendor exports are not always UTF-8.
    init(decodingCSV data: Data) {
        self = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }
}
