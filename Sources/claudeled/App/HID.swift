// HID.swift -- finding keyboards and holding the ones we are allowed to drive.

import Foundation
import IOKit
import IOKit.hid

struct KeyboardInfo {
    let device: IOHIDDevice
    let element: IOHIDElement?
    let name: String
    let vendor: Int
    let product: Int
    let transport: String
    var drivable: Bool { element != nil }
}

enum HID {
    static func capsElement(_ device: IOHIDDevice) -> IOHIDElement? {
        let elements = (IOHIDDeviceCopyMatchingElements(
            device, [kIOHIDElementUsagePageKey: Int(kHIDPage_LEDs)] as CFDictionary, 0)
            as? [IOHIDElement]) ?? []
        return elements.first { IOHIDElementGetUsage($0) == UInt32(kHIDUsage_LED_CapsLock) }
    }

    static func describe(_ device: IOHIDDevice) -> KeyboardInfo {
        func property<T>(_ key: String) -> T? {
            IOHIDDeviceGetProperty(device, key as CFString) as? T
        }
        return KeyboardInfo(
            device: device,
            element: capsElement(device),
            name: property(kIOHIDProductKey) ?? "Unknown keyboard",
            vendor: property(kIOHIDVendorIDKey) ?? -1,
            product: property(kIOHIDProductIDKey) ?? -1,
            transport: property(kIOHIDTransportKey) ?? "?")
    }

    static var keyboardMatch: CFArray {
        [[kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
          kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]] as CFArray
    }

    /// One-shot enumeration, for the CLI.
    static func enumerate() -> [KeyboardInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, keyboardMatch)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        return devices.map(describe).sorted { $0.name < $1.name }
    }
}

/// Live registry driven by IOHIDManager callbacks, so sleep, Bluetooth reconnects and
/// receiver unplugs are handled without polling.
final class KeyboardRegistry {
    private let lock = NSLock()
    private var open: [(device: IOHIDDevice, element: IOHIDElement)] = []
    private var known: [IOHIDDevice] = []
    private var manager: IOHIDManager?

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, HID.keyboardMatch)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<KeyboardRegistry>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<KeyboardRegistry>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    private func attach(_ device: IOHIDDevice) {
        lock.lock()
        if !known.contains(device) { known.append(device) }
        lock.unlock()
        reopen()
    }

    private func detach(_ device: IOHIDDevice) {
        lock.lock()
        known.removeAll { $0 == device }
        open.removeAll { $0.device == device }
        lock.unlock()
    }

    /// Also called when the selection changes, so ticking a keyboard takes effect at once.
    func reopen() {
        let config = Config.load()
        lock.lock()
        for entry in open {
            write(entry, on: false)
            IOHIDDeviceClose(entry.device, 0)
        }
        open.removeAll()
        for device in known {
            let info = HID.describe(device)
            guard let element = info.element, config.selects(info.name),
                  IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { continue }
            open.append((device, element))
        }
        lock.unlock()
    }

    private func write(_ entry: (device: IOHIDDevice, element: IOHIDElement), on: Bool) {
        let value = IOHIDValueCreateWithIntegerValue(
            kCFAllocatorDefault, entry.element, 0, on ? 1 : 0)
        IOHIDDeviceSetValue(entry.device, entry.element, value)
    }

    func set(_ on: Bool) {
        lock.lock()
        let snapshot = open
        lock.unlock()
        for entry in snapshot { write(entry, on: on) }
    }

    /// Every keyboard seen so far, selected or not. The menu lists these.
    func inventory() -> [KeyboardInfo] {
        lock.lock()
        let devices = known
        lock.unlock()
        return devices.map(HID.describe).sorted { $0.name < $1.name }
    }
}
