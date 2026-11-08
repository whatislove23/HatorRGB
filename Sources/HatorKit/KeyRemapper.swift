import Foundation

/// What an F-key on the HATOR keyboard should do. Raw value = destination HID usage
/// as (usagePage << 32) | usage, the format `hidutil`'s UserKeyMapping expects.
public enum KeyAction: UInt64, CaseIterable, Codable, Sendable, Identifiable {
    case functionKey = 0
    case brightnessDown = 0xFF01_0000_0021   // Apple vendor keyboard page
    case brightnessUp = 0x0C_0000_006F       // Consumer: brightness increment
    case missionControl = 0xFF01_0000_0010
    case spotlight = 0xFF01_0000_0001
    case launchpad = 0xFF01_0000_0004
    case search = 0x0C_0000_0221             // Consumer: AC Search
    case sleep = 0x01_0000_0082              // Generic desktop: system sleep
    case previousTrack = 0x0C_0000_00B6
    case playPause = 0x0C_0000_00CD
    case nextTrack = 0x0C_0000_00B5
    case mute = 0x0C_0000_00E2
    case volumeDown = 0x0C_0000_00EA
    case volumeUp = 0x0C_0000_00E9

    public var id: UInt64 { rawValue }

    public var name: String {
        switch self {
        case .functionKey: "Звичайна F-клавіша"
        case .brightnessDown: "Яскравість −"
        case .brightnessUp: "Яскравість +"
        case .missionControl: "Mission Control"
        case .spotlight: "Spotlight"
        case .launchpad: "Launchpad"
        case .search: "Пошук"
        case .sleep: "Сон"
        case .previousTrack: "Попередній трек"
        case .playPause: "Відтворення / пауза"
        case .nextTrack: "Наступний трек"
        case .mute: "Без звуку"
        case .volumeDown: "Гучність −"
        case .volumeUp: "Гучність +"
        }
    }

    public var symbol: String {
        switch self {
        case .functionKey: "fn"
        case .brightnessDown: "sun.min"
        case .brightnessUp: "sun.max"
        case .missionControl: "rectangle.3.group"
        case .spotlight, .search: "magnifyingglass"
        case .launchpad: "square.grid.3x3"
        case .sleep: "moon"
        case .previousTrack: "backward"
        case .playPause: "playpause"
        case .nextTrack: "forward"
        case .mute: "speaker.slash"
        case .volumeDown: "speaker.wave.1"
        case .volumeUp: "speaker.wave.3"
        }
    }
}

public struct FKeyMapping: Codable, Equatable, Sendable {
    /// Index 0 = F1 … 11 = F12.
    public var actions: [KeyAction]

    public init(actions: [KeyAction]) {
        precondition(actions.count == 12)
        self.actions = actions
    }

    /// MacBook-style row.
    public static let macBook = FKeyMapping(actions: [
        .brightnessDown, .brightnessUp, .missionControl, .spotlight, .launchpad, .sleep,
        .previousTrack, .playPause, .nextTrack, .mute, .volumeDown, .volumeUp,
    ])
}

/// Remaps keys of the HATOR keyboard only, at the HID driver level, via `hidutil`.
/// No Accessibility / Input Monitoring permission needed. The mapping lives until the
/// keyboard is unplugged or the Mac restarts, so re-apply it on every connect.
public enum KeyRemapper {
    private static let matching =
        "{\"VendorID\":\(HatorProtocol.vendorID),\"ProductID\":\(HatorProtocol.productID)}"

    /// HID keyboard usage of F1 is 0x3A; F1…F12 are contiguous.
    private static func fKeyUsage(_ index: Int) -> UInt64 { 0x7_0000_0000 | UInt64(0x3A + index) }

    public static func apply(_ mapping: FKeyMapping?) throws {
        var entries: [String] = []
        if let mapping {
            for (i, action) in mapping.actions.enumerated() where action != .functionKey {
                entries.append(String(
                    format: "{\"HIDKeyboardModifierMappingSrc\":%llu,\"HIDKeyboardModifierMappingDst\":%llu}",
                    fKeyUsage(i), action.rawValue))
            }
        }
        try run(["property", "--matching", matching,
                 "--set", "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"])
    }

    public static func clear() throws { try apply(nil) }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "hidutil", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "hidutil: \(msg)"])
        }
    }
}
