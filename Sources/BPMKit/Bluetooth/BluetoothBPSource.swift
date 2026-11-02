@preconcurrency import CoreBluetooth
import Foundation

public enum BluetoothBPError: LocalizedError {
    case unauthorized
    case poweredOff
    case unsupported
    case noDevice
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Bluetooth access was denied. Allow it in System Settings › Privacy & Security › Bluetooth."
        case .poweredOff: "Bluetooth is turned off."
        case .unsupported: "This Mac does not support Bluetooth Low Energy."
        case .noDevice: "No blood pressure monitor was found. Start the monitor's Bluetooth transfer and try again."
        case let .connectionFailed(reason): "Could not connect to the monitor: \(reason)"
        }
    }
}

/// Any monitor implementing the standard Blood Pressure Service (0x1810).
///
/// Scans for the first monitor advertising the service, subscribes to Blood
/// Pressure Measurement (0x2A35) indications and collects readings until the
/// monitor disconnects or goes quiet. Monitors usually send their stored
/// readings right after the subscription, then disconnect.
public struct BluetoothBPSource: ReadingSource {
    public static let serviceUUID = CBUUID(string: "1810")
    public static let measurementUUID = CBUUID(string: "2A35")

    public var name: String { "Bluetooth blood pressure monitor" }
    public var scanTimeout: Duration
    public var idleTimeout: Duration

    public init(scanTimeout: Duration = .seconds(30), idleTimeout: Duration = .seconds(8)) {
        self.scanTimeout = scanTimeout
        self.idleTimeout = idleTimeout
    }

    public func fetchReadings(progress: @escaping @Sendable (String) -> Void) async throws -> [DeviceReading] {
        let session = BluetoothSession(scanTimeout: scanTimeout, idleTimeout: idleTimeout, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.start(continuation)
            }
        } onCancel: {
            session.cancel()
        }
    }

    /// Converts a decoded measurement. Readings without a usable device
    /// timestamp are stamped with `receivedAt`.
    public static func reading(from m: BloodPressureMeasurement, receivedAt: Date, deviceID: String,
                               deviceName: String, timeZone: TimeZone = .current) -> DeviceReading {
        DeviceReading(timestamp: m.date(in: timeZone) ?? receivedAt,
                      systolic: Int(m.systolic.rounded()), diastolic: Int(m.diastolic.rounded()),
                      pulse: m.pulseRate.map { Int($0.rounded()) },
                      irregularHeartbeat: m.irregularPulse, bodyMovement: m.bodyMovement,
                      deviceID: deviceID, deviceName: deviceName, deviceUser: m.userID)
    }
}

/// One scan-connect-collect run. All state is confined to `queue`.
private final class BluetoothSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "BluetoothBPSource")
    private let scanTimeout: Duration
    private let idleTimeout: Duration
    private let progress: @Sendable (String) -> Void

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var continuation: CheckedContinuation<[DeviceReading], Error>?
    private var readings: [DeviceReading] = []
    private var timer: DispatchWorkItem?

    init(scanTimeout: Duration, idleTimeout: Duration, progress: @escaping @Sendable (String) -> Void) {
        self.scanTimeout = scanTimeout
        self.idleTimeout = idleTimeout
        self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<[DeviceReading], Error>) {
        queue.async {
            self.continuation = continuation
            self.progress("Starting Bluetooth…")
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<[DeviceReading], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        if let central {
            if central.isScanning { central.stopScan() }
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
        continuation.resume(with: result)
    }

    /// Ends the run after `after` without further progress.
    private func arm(_ after: Duration, _ onTimeout: @escaping () -> Void) {
        timer?.cancel()
        let item = DispatchWorkItem(block: onTimeout)
        timer = item
        let (seconds, atto) = after.components
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(seconds * 1000 + atto / 1_000_000_000_000_000)), execute: item)
    }

    private func finishWithReadings() {
        if readings.isEmpty, peripheral?.state != .connected {
            finish(.failure(BluetoothBPError.noDevice))
        } else {
            finish(.success(readings))
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            progress("Looking for a monitor… Start its Bluetooth transfer now.")
            central.scanForPeripherals(withServices: [BluetoothBPSource.serviceUUID])
            arm(scanTimeout) { [weak self] in self?.finish(.failure(BluetoothBPError.noDevice)) }
        case .unauthorized: finish(.failure(BluetoothBPError.unauthorized))
        case .poweredOff: finish(.failure(BluetoothBPError.poweredOff))
        case .unsupported: finish(.failure(BluetoothBPError.unsupported))
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        progress("Connecting to \(peripheral.name ?? "monitor")…")
        central.connect(peripheral)
        arm(.seconds(15)) { [weak self] in self?.finish(.failure(BluetoothBPError.connectionFailed("timed out"))) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        progress("Connected. Waiting for readings…")
        peripheral.discoverServices([BluetoothBPSource.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(.failure(BluetoothBPError.connectionFailed(error?.localizedDescription ?? "unknown error")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Monitors typically disconnect once their memory has been sent.
        finish(.success(readings))
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BluetoothBPSource.serviceUUID }) else {
            return finish(.failure(BluetoothBPError.connectionFailed(error?.localizedDescription ?? "no blood pressure service")))
        }
        peripheral.discoverCharacteristics([BluetoothBPSource.measurementUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == BluetoothBPSource.measurementUUID }) else {
            return finish(.failure(BluetoothBPError.connectionFailed(error?.localizedDescription ?? "no measurement characteristic")))
        }
        peripheral.setNotifyValue(true, for: characteristic)
        arm(idleTimeout) { [weak self] in self?.finishWithReadings() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            finish(.failure(BluetoothBPError.connectionFailed(error.localizedDescription)))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BluetoothBPSource.measurementUUID, let data = characteristic.value,
              let measurement = try? BloodPressureMeasurement(bytes: Array(data)) else { return }
        readings.append(BluetoothBPSource.reading(
            from: measurement, receivedAt: Date(),
            deviceID: "ble:\(peripheral.identifier.uuidString)",
            deviceName: peripheral.name ?? "Bluetooth monitor"))
        progress("Received \(readings.count) reading\(readings.count == 1 ? "" : "s")…")
        arm(idleTimeout) { [weak self] in self?.finishWithReadings() }
    }
}
