import Foundation

/// HATOR Gaming Keyboard (USB 0416:b23c, Nuvoton NUC121) lighting protocol.
/// Vendor HID interface: usage page 0xFF1B, usage 0x91, report ID 1, 63-byte output reports.
public enum HatorProtocol {
    public static let vendorID = 0x0416
    public static let productID = 0xB23C
    public static let usagePage = 0xFF1B
    public static let reportID: UInt8 = 1
    public static let payloadSize = 63

    /// Per-key LEDs form a 6 × 22 matrix sent in 8 messages (7 × 18 keys + 1 × 6 keys).
    public static let rows = 6
    public static let columns = 22
    public static let slotCount = rows * columns // 132
    /// Per-key colour channels saturate at 0xC1 on this firmware.
    public static let perKeyMax: UInt8 = 0xC1
}

public struct RGB: Codable, Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public static let black = RGB(0, 0, 0)
    public static let white = RGB(255, 255, 255)

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }
    public var hex: String { String(format: "%02X%02X%02X", r, g, b) }
}

public enum Effect: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case staticColor = 0, breathe = 1, wave = 2, neon = 3, snake = 5
    case reactive = 6, aurora = 7, ripple = 8
    /// Per-key custom colours (set via the per-key messages first).
    case custom = 10

    public var id: UInt8 { rawValue }
    public static var presets: [Effect] { allCases.filter { $0 != .custom } }

    public var name: String {
        switch self {
        case .staticColor: "Static"
        case .breathe: "Breathe"
        case .wave: "Wave"
        case .neon: "Neon"
        case .snake: "Snake"
        case .reactive: "Reactive"
        case .aurora: "Aurora"
        case .ripple: "Ripple"
        case .custom: "Per-key"
        }
    }
    public var usesDirection: Bool { [.wave, .snake, .aurora].contains(self) }
    public var usesSpeed: Bool { self != .staticColor }
    public var usesBackground: Bool { [.breathe, .wave, .neon, .reactive, .ripple].contains(self) }
}

public enum Direction: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case right = 0, left, up, down, outward, inward, clockwise, counterClockwise
    public var id: UInt8 { rawValue }
    public var name: String {
        switch self {
        case .right: "→ Right"
        case .left: "← Left"
        case .up: "↑ Up"
        case .down: "↓ Down"
        case .outward: "Outward"
        case .inward: "Inward"
        case .clockwise: "Clockwise"
        case .counterClockwise: "Counter-clockwise"
        }
    }
}

public enum Zone: Sendable { case keys, logo }

public struct EffectSettings: Codable, Equatable, Sendable {
    public var effect: Effect = .wave
    public var brightness: UInt8 = 4   // 0…4
    public var speed: UInt8 = 2        // 0…4
    public var foreground: RGB = RGB(255, 0, 0)
    public var background: RGB = .black
    public var direction: Direction = .right
    public var rainbow: Bool = true
    public init() {}
}

public enum Packets {
    /// Command 7 (keys) / 8 (logo): set an effect. Returns the 63-byte payload (without report ID).
    public static func effect(_ s: EffectSettings, zone: Zone = .keys) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: HatorProtocol.payloadSize)
        p[0] = zone == .keys ? 0x07 : 0x08
        p[4] = zone == .keys ? 0x0E : 0x0D
        p[5] = s.effect.rawValue
        p[6] = min(s.brightness, 4)
        p[7] = min(s.speed, 4)
        p[8] = s.foreground.r; p[9] = s.foreground.g; p[10] = s.foreground.b
        p[11] = s.background.r; p[12] = s.background.g; p[13] = s.background.b
        p[14] = s.direction.rawValue
        p[15] = s.rainbow ? 1 : 0
        return p
    }

    /// Command 9: per-key colours for all 132 slots, as 8 payloads.
    public static func perKey(_ colors: [RGB]) -> [[UInt8]] {
        precondition(colors.count == HatorProtocol.slotCount)
        func scale(_ v: UInt8) -> UInt8 { UInt8(UInt16(v) * UInt16(HatorProtocol.perKeyMax) / 255) }
        var out: [[UInt8]] = []
        for msg in 0..<8 {
            let keys = msg == 7 ? 6 : 18
            var p = [UInt8](repeating: 0, count: HatorProtocol.payloadSize)
            p[0] = 0x09
            p[3] = UInt8(msg)
            p[4] = UInt8(keys * 3)
            for k in 0..<keys {
                let c = colors[msg * 18 + k]
                p[5 + k * 3] = scale(c.r); p[6 + k * 3] = scale(c.g); p[7 + k * 3] = scale(c.b)
            }
            out.append(p)
        }
        return out
    }
}
