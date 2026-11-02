import Foundation
import IOKit
import IOKit.serial

/// A serial callout device with the USB identity of the bridge behind it, if any.
public struct USBSerialDevice: Sendable, Equatable {
    public var path: String
    public var vendorID: Int?
    public var productID: Int?
    public var productName: String?

    public var usbID: String {
        guard let vendorID, let productID else { return "not USB" }
        return String(format: "%04x:%04x", vendorID, productID)
    }
}

public enum USBSerialDevices {
    /// All `/dev/cu.*` devices registered with IOKit.
    public static func all() -> [USBSerialDevice] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        let dict = matching as NSMutableDictionary
        dict[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [USBSerialDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(service, kIOCalloutDeviceKey, searchParents: false) as? String else { continue }
            devices.append(USBSerialDevice(
                path: path,
                vendorID: (property(service, "idVendor", searchParents: true) as? NSNumber)?.intValue,
                productID: (property(service, "idProduct", searchParents: true) as? NSNumber)?.intValue,
                productName: property(service, "USB Product Name", searchParents: true) as? String
            ))
        }
        return devices.sorted { $0.path < $1.path }
    }

    public static func matching(vendorID: Int, productID: Int) -> [USBSerialDevice] {
        all().filter { $0.vendorID == vendorID && $0.productID == productID }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String, searchParents: Bool) -> Any? {
        let options: IOOptionBits = searchParents ? IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents) : 0
        return IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
    }
}
