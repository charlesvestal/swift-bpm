import BPMKit
import Foundation
import Observation
import OSLog
import SwiftData

/// Imports from a Veroval BPM25 as soon as it is connected and in PC mode,
/// without asking. New device users are filed automatically (see
/// `ReadingImporter.autoLinkUnlinkedUsers`).
///
/// The PL2303 bridge can be present while the monitor is not answering, so
/// while the bridge is connected the monitor is polled until it replies.
/// After a successful download it waits a while before asking again.
@Observable
final class BPM25AutoImporter {
    enum Status: Equatable {
        case disabled
        case notConnected
        case waiting
        case importing
        case imported(ImportSummary, Date)
        case failed(String)
    }

    static let enabledKey = "autoImportBPM25"
    static let pollInterval = Duration.seconds(3)
    static let cooldown: TimeInterval = 120

    private(set) var status: Status = .notConnected
    /// Set while the manual import sheet uses the port.
    var suspended = false
    private(set) var isBusy = false

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var quietUntil = Date.distantPast
    @ObservationIgnored private let log = Logger(subsystem: "com.charlesvestal.BPTracker", category: "auto-import")
    @ObservationIgnored private let onImport: (ImportSummary) -> Void

    init(context: ModelContext, onImport: @escaping (ImportSummary) -> Void = { _ in }) {
        self.context = context
        self.onImport = onImport
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Waits for an in-flight download to finish, then keeps the port free.
    func suspend() async {
        suspended = true
        while isBusy { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func resume() {
        suspended = false
    }

    private func tick() async {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            status = .disabled
            return
        }
        guard !suspended else { return }
        guard let port = BPM25Source.connected().first?.portPath else {
            if status != .notConnected {
                log.info("BPM25 disconnected")
                status = .notConnected
            }
            // Plugging it in again should import straight away.
            quietUntil = .distantPast
            return
        }
        guard Date() >= quietUntil else { return }

        isBusy = true
        defer { isBusy = false }
        if case .imported = status {} else { status = .waiting }
        do {
            let readings = try await BPM25Source(portPath: port, firstByteTimeout: .seconds(1)).fetchReadings { _ in }
            status = .importing
            quietUntil = Date().addingTimeInterval(Self.cooldown)
            let summary = try store(readings)
            log.info("BPM25 imported: \(summary.message, privacy: .public)")
            status = .imported(summary, Date())
            onImport(summary)
        } catch BPM25Error.noResponse {
            // Connected but not in PC mode yet; keep polling.
            if case .imported = status {} else { status = .waiting }
        } catch {
            log.error("BPM25 auto-import failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            quietUntil = Date().addingTimeInterval(10)
        }
    }

    private func store(_ readings: [DeviceReading]) throws -> ImportSummary {
        // Background imports should not end up on the window's undo stack.
        context.undoManager?.disableUndoRegistration()
        defer { context.undoManager?.enableUndoRegistration() }
        let importer = ReadingImporter(context: context)
        let created = try importer.autoLinkUnlinkedUsers(in: readings)
        var summary = try importer.importDeviceReadings(readings)
        summary.createdProfiles = created
        return summary
    }
}
