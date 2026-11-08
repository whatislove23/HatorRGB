import Foundation
import IOKit.hid

public enum HatorError: Error, CustomStringConvertible {
    case notConnected
    case io(IOReturn)
    public var description: String {
        switch self {
        case .notConnected: "Keyboard not connected"
        case .io(let r): String(format: "HID write failed (0x%08x)", r)
        }
    }
}

/// Finds the keyboard's vendor HID interface, tracks hot-plug and sends lighting commands.
/// Must be used from the thread whose run loop it was started on (the main thread in the app).
public final class HatorDevice {
    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    /// Called on connect (true) and disconnect (false).
    public var onConnectionChange: ((Bool) -> Void)?
    public var isConnected: Bool { device != nil }

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: HatorProtocol.vendorID,
            kIOHIDProductIDKey: HatorProtocol.productID,
            kIOHIDPrimaryUsagePageKey: HatorProtocol.usagePage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<HatorDevice>.fromOpaque(ctx!).takeUnretainedValue()
            me.attach(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<HatorDevice>.fromOpaque(ctx!).takeUnretainedValue()
            if me.device == dev { me.device = nil; me.onConnectionChange?(false) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        // Devices already present are reported through the matching callback once the run loop spins;
        // pick them up synchronously too so CLI use works immediately.
        if let devs = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let d = devs.first { attach(d) }
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ dev: IOHIDDevice) {
        guard device != dev else { return }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        device = dev
        onConnectionChange?(true)
    }

    /// Sends one 63-byte payload as output report 1.
    public func send(_ payload: [UInt8]) throws {
        guard let device else { throw HatorError.notConnected }
        var buf = [HatorProtocol.reportID] + payload
        buf += [UInt8](repeating: 0, count: max(0, HatorProtocol.payloadSize + 1 - buf.count))
        let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(HatorProtocol.reportID), buf, buf.count)
        guard r == kIOReturnSuccess else { throw HatorError.io(r) }
    }

    public func apply(_ settings: EffectSettings, zone: Zone = .keys) throws {
        try send(Packets.effect(settings, zone: zone))
    }

    /// Writes 132 per-key colours and switches the keyboard into custom (per-key) mode.
    public func applyPerKey(_ colors: [RGB], brightness: UInt8 = 4) throws {
        for p in Packets.perKey(colors) { try send(p) }
        var s = EffectSettings()
        s.effect = .custom
        s.brightness = brightness
        s.speed = 3
        s.rainbow = true
        try apply(s)
    }
}
