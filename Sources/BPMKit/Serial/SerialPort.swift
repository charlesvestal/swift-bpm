import Darwin
import Foundation

public enum SerialPortError: Error, CustomStringConvertible {
    case open(path: String, errno: Int32)
    case configure(step: String, errno: Int32)
    case write(errno: Int32)
    case read(errno: Int32)
    case notOpen

    public var description: String {
        func reason(_ e: Int32) -> String { String(cString: strerror(e)) }
        switch self {
        case let .open(path, e): return "cannot open \(path): \(reason(e))"
        case let .configure(step, e): return "cannot configure port (\(step)): \(reason(e))"
        case let .write(e): return "write failed: \(reason(e))"
        case let .read(e): return "read failed: \(reason(e))"
        case .notOpen: return "port is not open"
        }
    }
}

/// A raw 8N1 serial port over a BSD callout device (`/dev/cu.*`).
public final class SerialPort {
    /// Bytes delivered by one `read(2)`, stamped relative to the start of the read call.
    public struct Chunk: Sendable {
        public var elapsed: Duration
        public var bytes: [UInt8]
    }

    public let path: String
    private var fd: Int32 = -1
    private var originalAttributes = termios()

    public init(path: String) {
        self.path = path
    }

    deinit { close() }

    public var isOpen: Bool { fd >= 0 }

    public func open(baudRate: Int) throws {
        // O_NONBLOCK so open() does not wait for carrier; cleared again below.
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw SerialPortError.open(path: path, errno: errno) }
        fd = descriptor

        do {
            guard ioctl(fd, TIOCEXCL) == 0 else { throw SerialPortError.configure(step: "exclusive access", errno: errno) }
            guard fcntl(fd, F_SETFL, 0) == 0 else { throw SerialPortError.configure(step: "blocking mode", errno: errno) }
            guard tcgetattr(fd, &originalAttributes) == 0 else { throw SerialPortError.configure(step: "read attributes", errno: errno) }

            var attributes = originalAttributes
            cfmakeraw(&attributes)
            attributes.c_cflag |= tcflag_t(CLOCAL | CREAD)
            attributes.c_cflag &= ~tcflag_t(CSTOPB | PARENB | CRTSCTS)
            attributes.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
            // Reads are driven by poll(); make read() return whatever is available.
            withUnsafeMutableBytes(of: &attributes.c_cc) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 0
            }
            // On Darwin the speed_t constants equal the numeric baud rate.
            guard cfsetspeed(&attributes, speed_t(baudRate)) == 0 else { throw SerialPortError.configure(step: "baud rate \(baudRate)", errno: errno) }
            guard tcsetattr(fd, TCSANOW, &attributes) == 0 else { throw SerialPortError.configure(step: "write attributes", errno: errno) }

            // Some USB-serial cables power the device side from DTR/RTS.
            var lines = TIOCM_DTR | TIOCM_RTS
            guard ioctl(fd, TIOCMBIS, &lines) == 0 else { throw SerialPortError.configure(step: "assert DTR/RTS", errno: errno) }

            tcflush(fd, TCIOFLUSH)
        } catch {
            Darwin.close(fd)
            fd = -1
            throw error
        }
    }

    public func close() {
        guard fd >= 0 else { return }
        tcsetattr(fd, TCSANOW, &originalAttributes)
        Darwin.close(fd)
        fd = -1
    }

    public func discardInput() {
        guard fd >= 0 else { return }
        tcflush(fd, TCIFLUSH)
    }

    public func write(_ bytes: [UInt8]) throws {
        guard fd >= 0 else { throw SerialPortError.notOpen }
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw SerialPortError.write(errno: errno)
            }
            sent += n
        }
        tcdrain(fd)
    }

    /// Reads until the line has been quiet for `idleTimeout` after the first
    /// byte, nothing arrives within `firstByteTimeout`, or `maxBytes` is reached.
    public func read(firstByteTimeout: Duration, idleTimeout: Duration, maxBytes: Int = 1 << 16) throws -> [Chunk] {
        guard fd >= 0 else { throw SerialPortError.notOpen }
        let clock = ContinuousClock()
        let start = clock.now
        var chunks: [Chunk] = []
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 4096)

        while total < maxBytes {
            let timeout = chunks.isEmpty ? firstByteTimeout : idleTimeout
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout.milliseconds))
            if ready < 0 {
                if errno == EINTR { continue }
                throw SerialPortError.read(errno: errno)
            }
            if ready == 0 { break }

            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, maxBytes - total)) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SerialPortError.read(errno: errno)
            }
            if n == 0 { break }
            chunks.append(Chunk(elapsed: clock.now - start, bytes: Array(buffer[0..<n])))
            total += n
        }
        return chunks
    }
}

extension Duration {
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
