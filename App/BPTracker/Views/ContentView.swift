import BPMKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum DeviceSourceKind: String, Identifiable {
    case bpm25, bluetooth
    var id: String { rawValue }
}

enum EditorRequest: Identifiable {
    case new(Profile)
    case edit(Reading)

    var id: String {
        switch self {
        case let .new(p): "new-\(p.uuid)"
        case let .edit(r): "edit-\(r.key)"
        }
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]

    @State private var selection: Profile?
    @State private var range: TimeRange = .month
    @State private var editor: EditorRequest?
    @State private var deviceImport: DeviceSourceKind?
    @State private var importingCSV = false
    @State private var export: ExportFile?
    @State private var alert: AlertMessage?

    var body: some View {
        NavigationSplitView {
            ProfileSidebar(selection: $selection)
        } detail: {
            if let selection {
                ProfileDetailView(profile: selection, range: $range, editor: $editor)
            } else if profiles.isEmpty {
                ContentUnavailableView {
                    Label("No profiles yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Create a profile, or import readings from a monitor and a profile will be set up for each of its users.")
                } actions: {
                    Button("Create Profile") { selection = createProfile(named: "Me") }
                }
            } else {
                ContentUnavailableView("Select a profile", systemImage: "person.2")
            }
        }
        .toolbar { toolbar }
        .onAppear {
            // Edit › Undo then covers deletes, edits and moves.
            context.undoManager = undoManager
            if selection == nil { selection = profiles.first }
        }
        .onChange(of: profiles) { _, new in
            if let current = selection, !new.contains(current) { selection = new.first }
            if selection == nil { selection = new.first }
        }
        .sheet(item: $editor) { request in
            ReadingEditor(request: request)
        }
        .sheet(item: $deviceImport) { kind in
            DeviceImportSheet(kind: kind)
        }
        .fileImporter(isPresented: $importingCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            importCSV(result)
        }
        .fileExporter(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                      document: export, contentType: export?.contentType ?? .commaSeparatedText,
                      defaultFilename: export?.filename) { result in
            if case let .failure(error) = result {
                alert = AlertMessage(title: "Export failed", message: error.localizedDescription)
            }
            export = nil
        }
        .alert(item: $alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let selection { editor = .new(selection) }
            } label: {
                Label("Add Reading", systemImage: "plus")
            }
            .keyboardShortcut("n")
            .disabled(selection == nil)
            .help("Enter a reading by hand")

            Menu {
                Button("Veroval BPM25 (USB)") { deviceImport = .bpm25 }
                    .keyboardShortcut("i")
                Button("Bluetooth Monitor") { deviceImport = .bluetooth }
                Divider()
                Button("CSV File…") { importingCSV = true }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Download readings from a monitor or import a CSV file")

            Menu {
                Button("PDF Report…") { exportPDF() }
                    .disabled(selection == nil)
                Divider()
                Button("CSV – This Profile…") { exportCSV(allProfiles: false) }
                    .disabled(selection == nil)
                Button("CSV – All Profiles…") { exportCSV(allProfiles: true) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export a PDF report or CSV file")
        }
    }

    @discardableResult
    private func createProfile(named name: String) -> Profile {
        let profile = Profile(name: name)
        context.insert(profile)
        try? context.save()
        return profile
    }

    private func importCSV(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let rows = try ReadingsCSV.decode(String(contentsOf: url, encoding: .utf8))
            let importer = ReadingImporter(context: context)
            let summary = try importer.importCSV(rows, fallbackProfile: selection ?? createProfile(named: "Me"))
            alert = AlertMessage(title: "Imported \(url.lastPathComponent)", message: summary.message)
        } catch {
            alert = AlertMessage(title: "Import failed", message: error.localizedDescription)
        }
    }

    private func exportCSV(allProfiles: Bool) {
        let readings: [Reading]
        let name: String
        if allProfiles {
            readings = (try? context.fetch(FetchDescriptor<Reading>())) ?? []
            name = "All Profiles"
        } else {
            guard let selection else { return }
            readings = selection.readings
            name = selection.name
        }
        let text = ReadingsCSV.encode(ReadingImporter.csvRows(for: readings))
        export = ExportFile(data: Data(text.utf8), contentType: .commaSeparatedText,
                            filename: "Blood Pressure – \(name) – \(Date().formatted(.iso8601.year().month().day())).csv")
    }

    private func exportPDF() {
        guard let selection else { return }
        let readings = selection.readings.filter { range.contains($0.timestamp) }
        guard !readings.isEmpty else {
            alert = AlertMessage(title: "Nothing to export", message: "\(selection.name) has no readings in the last \(range.rawValue).")
            return
        }
        let data = PDFReport.render(profileName: selection.name, rangeTitle: range.rawValue, readings: readings)
        export = ExportFile(data: data, contentType: .pdf,
                            filename: "Blood Pressure – \(selection.name) – \(Date().formatted(.iso8601.year().month().day())).pdf")
    }
}
