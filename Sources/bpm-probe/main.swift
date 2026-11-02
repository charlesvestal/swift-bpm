import BPMKit
import Foundation

// bpm-probe: talk to a Veroval BPM25 over its PL2303 bridge and dump exactly
// what comes back, so the documented protocol can be checked against a real
// device before anything is built on top of it.

let usage = """
usage: bpm-probe [options]

  --list               list serial devices and exit
  --port PATH          serial device (default: first 067b:2303 bridge)
  --baud N             baud rate (default 19200)
  --first-timeout MS   wait for the first response byte (default 3000)
  --idle-timeout MS    end of response after this much silence (default 1000)
  --no-close           do not send the A6 request after A5
  --out DIR            save raw responses as .bin files (default ./probe-captures)
  --no-save            do not save raw responses
  -h, --help           show this help

Put the monitor in PC/transfer mode before running.
"""

struct Options {
    var list = false
    var port: String?
    var baud = BPM25.baudRate
    var firstTimeout = Duration.milliseconds(3000)
    var idleTimeout = Duration.milliseconds(1000)
    var sendClose = true
    var outDir: String? = "probe-captures"
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("bpm-probe: \(message)\n".utf8))
    exit(1)
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    func value(_ flag: String) -> String {
        guard let v = args.popFirst() else { fail("\(flag) needs a value") }
        return v
    }
    func integer(_ flag: String) -> Int {
        guard let n = Int(value(flag)), n > 0 else { fail("\(flag) needs a positive integer") }
        return n
    }
    while let arg = args.popFirst() {
        switch arg {
        case "--list": options.list = true
        case "--port": options.port = value(arg)
        case "--baud": options.baud = integer(arg)
        case "--first-timeout": options.firstTimeout = .milliseconds(integer(arg))
        case "--idle-timeout": options.idleTimeout = .milliseconds(integer(arg))
        case "--no-close": options.sendClose = false
        case "--out": options.outDir = value(arg)
        case "--no-save": options.outDir = nil
        case "-h", "--help": print(usage); exit(0)
        default: fail("unknown option \(arg)\n\n\(usage)")
        }
    }
    return options
}

func hex(_ bytes: some Collection<UInt8>) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func hexDump(_ bytes: [UInt8]) {
    for row in stride(from: 0, to: bytes.count, by: 16) {
        let line = bytes[row..<min(row + 16, bytes.count)]
        let ascii = line.map { (0x20..<0x7F).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
        let hexPart = hex(line).padding(toLength: 47, withPad: " ", startingAt: 0)
        print(String(format: "  %04X  ", row) + hexPart + "  |" + ascii + "|")
    }
}

func ms(_ d: Duration) -> Int64 {
    let (s, atto) = d.components
    return s * 1000 + atto / 1_000_000_000_000_000
}

/// Checks which simple checksum, if any, produces the trailing byte.
func checksumReport(_ bytes: [UInt8]) -> String {
    guard bytes.count >= 2, let last = bytes.last else { return "n/a" }
    let body = bytes.dropLast()
    func sum(_ s: ArraySlice<UInt8>) -> UInt8 { s.reduce(0, &+) }
    func xor(_ s: ArraySlice<UInt8>) -> UInt8 { s.reduce(0, ^) }
    let candidates: [(String, UInt8)] = [
        ("sum(bytes[1..<last]) mod 256", sum(body.dropFirst())),
        ("sum(bytes[0..<last]) mod 256", sum(body)),
        ("-sum(bytes[0..<last]) mod 256", 0 &- sum(body)),
        ("xor(bytes[1..<last])", xor(body.dropFirst())),
        ("xor(bytes[0..<last])", xor(body)),
    ]
    let matches = candidates.filter { $0.1 == last }.map(\.0)
    let detail = candidates.map { "\($0.0)=\(String(format: "%02X", $0.1))" }.joined(separator: ", ")
    return matches.isEmpty
        ? "trailer \(String(format: "%02X", last)) matches none of: \(detail)"
        : "trailer \(String(format: "%02X", last)) = \(matches.joined(separator: " / "))"
}

func describe(_ response: BPM25.Response) {
    print("  header:   \(hex(response.header))" + (response.declaredCount.map { "  (declared records: \($0))" } ?? ""))
    print("  records:  \(response.records.count) parsed")
    print("  trailer:  \(response.trailer.isEmpty ? "(none)" : hex(response.trailer))")
    print("  checksum: \(checksumReport(response.bytes))")
    for issue in response.issues { print("  ! \(issue)") }
    guard !response.records.isEmpty else { return }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    print("")
    print("    #  user idx  device time        sys  dia  pulse flags  raw")
    for (n, r) in response.records.enumerated() {
        let time = r.date().map(formatter.string(from:))
            ?? String(format: "%04d-%02d-%02d %02d:%02d?", r.year, r.month, r.day, r.hour, r.minute)
        let issues = r.plausibilityIssues
        print(String(format: "  %3d  %4d %3d  ", n, r.user, r.index)
              + time.padding(toLength: 17, withPad: " ", startingAt: 0)
              + String(format: "  %3d  %3d  %5d  %02X%@   ", r.systolic, r.diastolic, r.pulse, r.flags, r.irregularHeartbeat ? "*" : " ")
              + hex(r.raw)
              + (issues.isEmpty ? "" : "   <- \(issues.joined(separator: ", "))"))
    }
    let users = Dictionary(grouping: response.records, by: \.user).mapValues(\.count)
    print("  per user byte: " + users.sorted { $0.key < $1.key }.map { "user \($0.key): \($0.value)" }.joined(separator: ", "))
    print("  (* = flags bit 0, documented as irregular heartbeat)")
}

@MainActor
func exchange(_ port: SerialPort, label: String, request: [UInt8]) throws {
    print("")
    print("=== \(label) ===")
    port.discardInput()
    print("-> \(hex(request))")
    try port.write(request)
    let chunks = try port.read(firstByteTimeout: options.firstTimeout, idleTimeout: options.idleTimeout)
    let bytes = chunks.flatMap(\.bytes)
    guard let first = chunks.first, let last = chunks.last else {
        print("<- no response within \(ms(options.firstTimeout)) ms")
        return
    }
    print("<- \(bytes.count) bytes in \(chunks.count) reads, first after \(ms(first.elapsed)) ms, last after \(ms(last.elapsed)) ms")
    hexDump(bytes)
    print("")
    describe(BPM25.parse(bytes))
    save(label, bytes)
}

let options = parseOptions()
let devices = USBSerialDevices.all()

if options.list {
    for d in devices {
        print("\(d.path)  \(d.usbID)  \(d.productName ?? "")")
    }
    exit(0)
}

let path: String
if let explicit = options.port {
    path = explicit
} else if let bridge = devices.first(where: { $0.vendorID == BPM25.usbVendorID && $0.productID == BPM25.usbProductID }) {
    path = bridge.path
} else {
    fail("no 067b:2303 serial bridge found (use --list to see devices, --port to pick one)")
}

let identity = devices.first { $0.path == path }
print("port:     \(path)  [\(identity?.usbID ?? "unknown")  \(identity?.productName ?? "")]")
print("settings: \(options.baud) 8N1, no flow control, DTR+RTS asserted")

let stamp: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}()
var saved: [String] = []
@MainActor
func save(_ label: String, _ bytes: [UInt8]) {
    guard let dir = options.outDir else { return }
    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(stamp)-\(label).bin")
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        saved.append(url.path)
    } catch {
        print("  ! could not save \(url.path): \(error)")
    }
}

let port = SerialPort(path: path)
do {
    try port.open(baudRate: options.baud)
    defer { port.close() }
    try exchange(port, label: "A5", request: BPM25.requestReadings)
    if options.sendClose {
        try exchange(port, label: "A6", request: BPM25.requestClose)
    }
} catch {
    fail("\(error)")
}

if !saved.isEmpty {
    print("")
    print("saved: " + saved.joined(separator: ", "))
}
