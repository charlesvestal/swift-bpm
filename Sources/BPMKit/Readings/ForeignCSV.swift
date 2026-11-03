import Foundation

/// Reads CSV exports from other blood-pressure apps by column position.
///
/// The presets describe the export layouts of common vendor apps. The layout
/// facts (first data line, delimiter, column positions, date formats, flag
/// values) were taken from the migration presets in UBPM's source
/// (DialogMigration.cpp, GPL-3.0); no UBPM code is used. Formats change
/// between app versions, so every field can be adjusted.
public struct ColumnMapping: Sendable, Equatable, Identifiable {
    public var name: String
    /// 1-based line number of the first data row.
    public var firstDataLine: Int
    public var delimiter: String
    /// 0-based column indexes.
    public var dateColumn: Int
    /// `DateFormatter` pattern for the date column, or date and time when
    /// `timeColumn` is nil.
    public var dateFormat: String
    public var timeColumn: Int?
    public var timeFormat: String
    public var systolicColumn: Int
    public var diastolicColumn: Int
    public var pulseColumn: Int?
    public var irregularColumn: Int?
    /// Values (case-insensitive, `|`-separated) that mean "irregular heartbeat".
    public var irregularValues: String
    public var movementColumn: Int?
    public var movementValues: String
    public var noteColumn: Int?

    public var id: String { name }

    public init(name: String, firstDataLine: Int, delimiter: String, dateColumn: Int, dateFormat: String,
                timeColumn: Int? = nil, timeFormat: String = "", systolicColumn: Int, diastolicColumn: Int,
                pulseColumn: Int? = nil, irregularColumn: Int? = nil, irregularValues: String = "",
                movementColumn: Int? = nil, movementValues: String = "", noteColumn: Int? = nil) {
        self.name = name
        self.firstDataLine = firstDataLine
        self.delimiter = delimiter
        self.dateColumn = dateColumn
        self.dateFormat = dateFormat
        self.timeColumn = timeColumn
        self.timeFormat = timeFormat
        self.systolicColumn = systolicColumn
        self.diastolicColumn = diastolicColumn
        self.pulseColumn = pulseColumn
        self.irregularColumn = irregularColumn
        self.irregularValues = irregularValues
        self.movementColumn = movementColumn
        self.movementValues = movementValues
        self.noteColumn = noteColumn
    }

    public static let presets: [ColumnMapping] = [
        ColumnMapping(name: "Beurer HealthManager", firstDataLine: 16, delimiter: ";", dateColumn: 0, dateFormat: "M/d/yyyy",
                      timeColumn: 1, timeFormat: "h:m a", systolicColumn: 3, diastolicColumn: 4, pulseColumn: 5,
                      irregularColumn: 8, irregularValues: "Yes", movementColumn: 9, movementValues: "Yes", noteColumn: 12),
        ColumnMapping(name: "Medisana", firstDataLine: 24, delimiter: ";", dateColumn: 0, dateFormat: "M/d/yyyy - h:m",
                      systolicColumn: 1, diastolicColumn: 2, pulseColumn: 3, noteColumn: 6),
        ColumnMapping(name: "Microlife", firstDataLine: 18, delimiter: ",", dateColumn: 0, dateFormat: "yyyy/M/d",
                      timeColumn: 1, timeFormat: "h:m a", systolicColumn: 2, diastolicColumn: 3, pulseColumn: 4,
                      irregularColumn: 7, irregularValues: "AFIB|PAD"),
        ColumnMapping(name: "OMRON connect", firstDataLine: 2, delimiter: ",", dateColumn: 0, dateFormat: "yyyy/M/d H:m",
                      systolicColumn: 2, diastolicColumn: 3, pulseColumn: 4, irregularColumn: 5, irregularValues: "Detected",
                      movementColumn: 7, movementValues: "Detected"),
        ColumnMapping(name: "Sanitas", firstDataLine: 19, delimiter: ",", dateColumn: 0, dateFormat: "d.M.yyyy",
                      timeColumn: 1, timeFormat: "H:m", systolicColumn: 3, diastolicColumn: 4, pulseColumn: 5,
                      irregularColumn: 7, irregularValues: "Yes", movementColumn: 8, movementValues: "Yes", noteColumn: 11),
        ColumnMapping(name: "Veroval medi.connect", firstDataLine: 18, delimiter: ",", dateColumn: 0, dateFormat: "d.M.yyyy",
                      timeColumn: 1, timeFormat: "h:m a", systolicColumn: 2, diastolicColumn: 3, pulseColumn: 4,
                      irregularColumn: 5, irregularValues: "Yes", noteColumn: 6),
    ]

    public static let custom = ColumnMapping(name: "Custom", firstDataLine: 2, delimiter: ",", dateColumn: 0,
                                             dateFormat: "yyyy-MM-dd", timeColumn: 1, timeFormat: "HH:mm",
                                             systolicColumn: 2, diastolicColumn: 3, pulseColumn: 4)

    /// A preset whose name appears in the file name, as vendor apps tend to name their exports.
    public static func guess(fileName: String) -> ColumnMapping? {
        let lower = fileName.lowercased()
        return presets.first { lower.contains($0.name.split(separator: " ")[0].lowercased()) }
    }

    public struct Result: Sendable {
        public var rows: [CSVReading]
        /// 1-based line numbers of data rows that could not be read.
        public var skippedLines: [Int]
    }

    public func decode(_ text: String, source: String? = nil, timeZone: TimeZone = .current) throws -> Result {
        guard let delimiterScalar = delimiter.unicodeScalars.first, delimiter.unicodeScalars.count == 1 else {
            throw ReadingsCSVError.badValue(line: 0, column: "delimiter", value: delimiter)
        }
        let records = try ReadingsCSV.parseRecords(text, delimiter: delimiterScalar)
        let dateParser = formatter(timeColumn == nil ? dateFormat : "\(dateFormat) \(timeFormat)", timeZone: timeZone)
        var rows: [CSVReading] = []
        var skipped: [Int] = []

        for (index, record) in records.enumerated() where index + 1 >= firstDataLine {
            let line = index + 1
            func field(_ col: Int?) -> String? {
                guard let col, col >= 0, col < record.count else { return nil }
                let v = record[col].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            if record.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }

            let rawDate = [field(dateColumn), timeColumn.flatMap { field($0) }].compactMap { $0 }.joined(separator: " ")
            guard let timestamp = dateParser.date(from: rawDate),
                  let systolic = field(systolicColumn).flatMap(Self.leadingInteger),
                  let diastolic = field(diastolicColumn).flatMap(Self.leadingInteger) else {
                skipped.append(line)
                continue
            }
            rows.append(CSVReading(
                timestamp: timestamp, systolic: systolic, diastolic: diastolic,
                pulse: field(pulseColumn).flatMap(Self.leadingInteger),
                irregularHeartbeat: Self.matches(field(irregularColumn), irregularValues),
                bodyMovement: Self.matches(field(movementColumn), movementValues),
                source: source ?? name, note: field(noteColumn)))
        }
        return Result(rows: rows, skippedLines: skipped)
    }

    /// First run of digits, so "120 mmHg" reads as 120.
    static func leadingInteger(_ s: String) -> Int? {
        guard let range = s.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(s[range])
    }

    static func matches(_ value: String?, _ accepted: String) -> Bool {
        guard let value, !accepted.isEmpty else { return false }
        return accepted.split(separator: "|").contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(value) == .orderedSame }
    }

    private func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        f.isLenient = true
        return f
    }
}
