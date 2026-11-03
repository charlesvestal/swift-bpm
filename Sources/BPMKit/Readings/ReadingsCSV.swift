import Foundation

/// One CSV row. `profile`, `deviceID` and friends are optional so files from
/// other tools with only date and pressure columns can still be imported.
public struct CSVReading: Equatable, Sendable {
    public var timestamp: Date
    public var profile: String?
    public var systolic: Int
    public var diastolic: Int
    public var pulse: Int?
    public var irregularHeartbeat: Bool
    public var bodyMovement: Bool
    public var source: String?
    public var deviceID: String?
    public var deviceUser: Int?
    public var note: String?
    /// Kept but left out of charts, statistics and reports.
    public var hidden: Bool

    public init(timestamp: Date, profile: String? = nil, systolic: Int, diastolic: Int, pulse: Int? = nil,
                irregularHeartbeat: Bool = false, bodyMovement: Bool = false, source: String? = nil,
                deviceID: String? = nil, deviceUser: Int? = nil, note: String? = nil, hidden: Bool = false) {
        self.timestamp = timestamp
        self.profile = profile
        self.systolic = systolic
        self.diastolic = diastolic
        self.pulse = pulse
        self.irregularHeartbeat = irregularHeartbeat
        self.bodyMovement = bodyMovement
        self.source = source
        self.deviceID = deviceID
        self.deviceUser = deviceUser
        self.note = note
        self.hidden = hidden
    }
}

public enum ReadingsCSVError: LocalizedError, Equatable {
    case empty
    case missingColumn(String)
    case badValue(line: Int, column: String, value: String)
    case unterminatedQuote(line: Int)

    public var errorDescription: String? {
        switch self {
        case .empty: "The file has no header row."
        case let .missingColumn(name): "The file has no \"\(name)\" column."
        case let .badValue(line, column, value): "Line \(line): \"\(value)\" is not a valid \(column)."
        case let .unterminatedQuote(line): "Line \(line): a quoted field is never closed."
        }
    }
}

public enum ReadingsCSV {
    public static let columns = ["timestamp", "profile", "systolic", "diastolic", "pulse",
                                 "irregular_heartbeat", "body_movement", "source", "device_id", "device_user", "note", "hidden"]

    public static func encode(_ rows: [CSVReading]) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var lines = [columns.joined(separator: ",")]
        for r in rows {
            let fields: [String] = [
                iso.string(from: r.timestamp),
                r.profile ?? "",
                String(r.systolic),
                String(r.diastolic),
                r.pulse.map(String.init) ?? "",
                r.irregularHeartbeat ? "1" : "0",
                r.bodyMovement ? "1" : "0",
                r.source ?? "",
                r.deviceID ?? "",
                r.deviceUser.map(String.init) ?? "",
                r.note ?? "",
                r.hidden ? "1" : "0",
            ]
            lines.append(fields.map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Requires `timestamp` (or `date` + `time`), `systolic` and `diastolic`
    /// columns; header names are matched case-insensitively.
    public static func decode(_ text: String, timeZone: TimeZone = .current) throws -> [CSVReading] {
        let records = try parseRecords(text)
        guard let header = records.first else { throw ReadingsCSVError.empty }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func index(_ name: String) -> Int? { names.firstIndex(of: name) }

        let timestampCol = index("timestamp")
        let dateCol = index("date"), timeCol = index("time")
        guard timestampCol != nil || dateCol != nil else { throw ReadingsCSVError.missingColumn("timestamp") }
        guard let sysCol = index("systolic") else { throw ReadingsCSVError.missingColumn("systolic") }
        guard let diaCol = index("diastolic") else { throw ReadingsCSVError.missingColumn("diastolic") }

        let dates = DateParser(timeZone: timeZone)
        var rows: [CSVReading] = []
        for (offset, record) in records.dropFirst().enumerated() {
            let line = offset + 2
            if record.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            func field(_ col: Int?) -> String? {
                guard let col, col < record.count else { return nil }
                let v = record[col].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            func int(_ col: Int?, _ name: String) throws -> Int? {
                guard let v = field(col) else { return nil }
                guard let n = Int(v) else { throw ReadingsCSVError.badValue(line: line, column: name, value: v) }
                return n
            }
            func bool(_ name: String) throws -> Bool {
                guard let v = field(index(name)) else { return false }
                switch v.lowercased() {
                case "1", "true", "yes", "y": return true
                case "0", "false", "no", "n": return false
                default: throw ReadingsCSVError.badValue(line: line, column: name, value: v)
                }
            }

            let rawTime = field(timestampCol) ?? [field(dateCol), field(timeCol)].compactMap { $0 }.joined(separator: " ")
            guard let timestamp = dates.parse(rawTime) else {
                throw ReadingsCSVError.badValue(line: line, column: "timestamp", value: rawTime)
            }
            guard let systolic = try int(sysCol, "systolic") else {
                throw ReadingsCSVError.badValue(line: line, column: "systolic", value: "")
            }
            guard let diastolic = try int(diaCol, "diastolic") else {
                throw ReadingsCSVError.badValue(line: line, column: "diastolic", value: "")
            }
            rows.append(CSVReading(
                timestamp: timestamp,
                profile: field(index("profile")),
                systolic: systolic,
                diastolic: diastolic,
                pulse: try int(index("pulse"), "pulse"),
                irregularHeartbeat: try bool("irregular_heartbeat"),
                bodyMovement: try bool("body_movement"),
                source: field(index("source")),
                deviceID: field(index("device_id")),
                deviceUser: try int(index("device_user"), "device_user"),
                note: field(index("note")),
                hidden: try bool("hidden")
            ))
        }
        return rows
    }

    static func quote(_ field: String) -> String {
        guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC 4180 records: quoted fields may contain commas, quotes and newlines.
    static func parseRecords(_ text: String, delimiter: Unicode.Scalar = ",") throws -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var quoteStartLine = 1
        var chars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return chars.next()
        }

        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = n }
                    } else {
                        inQuotes = false
                    }
                } else {
                    if c == "\n" { line += 1 }
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty:
                inQuotes = true
                quoteStartLine = line
            case delimiter:
                record.append(field)
                field = ""
            case "\r":
                break
            case "\n":
                record.append(field)
                records.append(record)
                record = []
                field = ""
                line += 1
            default:
                field.unicodeScalars.append(c)
            }
        }
        if inQuotes { throw ReadingsCSVError.unterminatedQuote(line: quoteStartLine) }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        // A UTF-8 byte order mark from spreadsheet exports.
        if let first = records.first?.first, first.hasPrefix("\u{FEFF}") {
            records[0][0] = String(first.dropFirst())
        }
        return records
    }

    private struct DateParser {
        let iso: ISO8601DateFormatter
        let formats: [DateFormatter]

        init(timeZone: TimeZone) {
            iso = ISO8601DateFormatter()
            // Formats without an offset are read in `timeZone`.
            formats = ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"].map {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = timeZone
                f.dateFormat = $0
                return f
            }
        }

        func parse(_ s: String) -> Date? {
            iso.date(from: s) ?? formats.lazy.compactMap { $0.date(from: s) }.first
        }
    }
}
