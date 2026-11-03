import AppKit
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

/// What the sidebar has selected: a profile, or one of its measurement weeks.
enum SidebarItem: Hashable {
    case profile(UUID)
    case week(UUID)
}

/// A picked vendor CSV waiting for its column mapping.
struct ForeignImportRequest: Identifiable {
    let id = UUID()
    var fileName: String
    var text: String
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

    @Query(sort: \MeasurementWeek.start, order: .reverse) private var weeks: [MeasurementWeek]
    @State private var sidebarSelection: SidebarItem?
    @State private var newWeekFor: Profile?
    @State private var period = Period()
    @State private var editor: EditorRequest?
    @State private var deviceImport: DeviceSourceKind?
    @State private var importingCSV = false
    /// Which kind of CSV the open panel is for.
    @State private var csvIsForeign = false
    @State private var foreignImport: ForeignImportRequest?
    @State private var export: ExportFile?
    @State private var alert: AlertMessage?

    var body: some View {
        NavigationSplitView {
            ProfileSidebar(selection: $sidebarSelection, newWeekFor: $newWeekFor)
        } detail: {
            if let week = selectedWeek, let profile = selection {
                MeasurementWeekView(week: week, profile: profile) { sidebarSelection = .profile(profile.uuid) }
            } else if let selection {
                ProfileDetailView(profile: selection, period: $period, editor: $editor)
            } else if profiles.isEmpty {
                ContentUnavailableView {
                    Label("No profiles yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Create a profile, or import readings from a monitor and a profile will be set up for each of its users.")
                } actions: {
                    Button("Create Profile") { select(createProfile(named: "Me")) }
                }
            } else {
                ContentUnavailableView("Select a profile", systemImage: "person.2")
            }
        }
        .toolbar { toolbar }
        .onAppear {
            // Edit › Undo then covers deletes, edits and moves.
            context.undoManager = undoManager
            if selection == nil { select(profiles.first) }
        }
        .onChange(of: profiles) { _, new in
            if let current = selection, !new.contains(current) { select(new.first) }
            if selection == nil { select(new.first) }
        }
        .onChange(of: weeks) {
            if case .week = sidebarSelection, selectedWeek == nil { select(selection ?? profiles.first) }
        }
        .sheet(item: $newWeekFor) { profile in
            StartWeekSheet(profile: profile) { sidebarSelection = .week($0.uuid) }
        }
        .sheet(item: $editor) { request in
            ReadingEditor(request: request)
        }
        .sheet(item: $deviceImport) { kind in
            DeviceImportSheet(kind: kind)
        }
        .sheet(item: $foreignImport) { request in
            ForeignImportSheet(fileName: request.fileName, text: request.text, initialProfile: selection) { summary in
                alert = AlertMessage(title: "Imported \(request.fileName)", message: summary.message)
            }
        }
        .fileImporter(isPresented: $importingCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if csvIsForeign { openForeignCSV(result) } else { importCSV(result) }
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
            Menu {
                Button("Reading…") { if let selection { editor = .new(selection) } }
                    .keyboardShortcut("n")
                Button("Measurement Week…") { newWeekFor = selection }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                if let selection { editor = .new(selection) }
            }
            .disabled(selection == nil)
            .help("Add a reading, or start a measurement week")

            Menu {
                Button("Veroval BPM25 (USB)") { deviceImport = .bpm25 }
                    .keyboardShortcut("i")
                Button("Bluetooth Monitor") { deviceImport = .bluetooth }
                Divider()
                Button("CSV File…") {
                    csvIsForeign = false
                    importingCSV = true
                }
                Button("From Another App…") {
                    csvIsForeign = true
                    importingCSV = true
                }
                .help("OMRON, Beurer, Medisana, Microlife, Sanitas, Veroval or any other CSV")
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Download readings from a monitor or import a CSV file")

            Menu {
                Button("PDF Report…") { exportPDF() }
                    .disabled(selection == nil)
                Button("Share PDF Report…") { sharePDF() }
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

    /// The selected profile, or the profile of the selected week.
    private var selection: Profile? {
        switch sidebarSelection {
        case let .profile(id): profiles.first { $0.uuid == id }
        case .week: selectedWeek.flatMap { week in profiles.first { $0.uuid == week.profileID } }
        case nil: nil
        }
    }

    private var selectedWeek: MeasurementWeek? {
        guard case let .week(id) = sidebarSelection else { return nil }
        return weeks.first { $0.uuid == id }
    }

    private func select(_ profile: Profile?) {
        sidebarSelection = profile.map { .profile($0.uuid) }
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

    private func openForeignCSV(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            foreignImport = ForeignImportRequest(fileName: url.lastPathComponent, text: String(decodingCSV: try Data(contentsOf: url)))
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

    private var reportFilename: String? {
        selection.map { "Blood Pressure – \($0.name) – \(Date().formatted(.iso8601.year().month().day())).pdf" }
    }

    /// The report for the selected profile and period, or nil (with an alert) when it would be empty.
    private func renderReport() -> Data? {
        guard let selection else { return nil }
        guard selection.readings.contains(where: { !$0.hidden && period.contains($0.timestamp) }) else {
            alert = AlertMessage(title: "Nothing to export", message: "\(selection.name) has no readings in \(period.title.lowercased()).")
            return nil
        }
        return PDFReport.render(profileName: selection.name, period: period, readings: selection.readings)
    }

    private func exportPDF() {
        guard let data = renderReport(), let filename = reportFilename else { return }
        export = ExportFile(data: data, contentType: .pdf, filename: filename)
    }

    /// Writes the report to a temporary file and offers the system share menu (Mail, Messages, AirDrop…).
    private func sharePDF() {
        guard let data = renderReport(), let filename = reportFilename,
              let view = NSApp.keyWindow?.contentView else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appending(path: filename)
            try data.write(to: url, options: .atomic)
            let picker = NSSharingServicePicker(items: [url])
            let anchor = NSRect(x: view.bounds.maxX - 60, y: view.bounds.maxY - 1, width: 1, height: 1)
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        } catch {
            alert = AlertMessage(title: "Share failed", message: error.localizedDescription)
        }
    }
}
