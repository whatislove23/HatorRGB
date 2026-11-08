import Foundation

/// Maps the 132 LED slots (6 rows × 22 columns, slot = row * 22 + column) to key labels.
/// `nil` means "no LED / unknown" and the slot is hidden in the editor.
/// The default guess follows the reverse-engineered PCMK TKL map; the app's calibration overwrites it.
public struct KeyLayout: Codable, Equatable, Sendable {
    public var labels: [String?]

    public init(labels: [String?]) {
        precondition(labels.count == HatorProtocol.slotCount)
        self.labels = labels
    }

    public static func slot(row: Int, column: Int) -> Int { row * HatorProtocol.columns + column }

    public static let `default`: KeyLayout = {
        let rows: [[String?]] = [
            ["Esc", nil, "F1", "F2", "F3", "F4", nil, "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
             "PrtSc", "ScrLk", "Pause", nil, nil, nil, nil],
            ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", nil, "⌫",
             "Ins", "Home", "PgUp", "Num", "/", "*", "−"],
            ["Tab", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\", nil,
             "Del", "End", "PgDn", "7", "8", "9", "+"],
            ["Caps", nil, "A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'", nil, "Enter",
             nil, nil, nil, "4", "5", "6", nil],
            ["⇧", nil, "Z", "X", "C", "V", "B", "N", "M", ",", ".", "/", nil, nil, "⇧",
             nil, "↑", nil, "1", "2", "3", "↵"],
            ["Ctrl", "Win", "Alt", nil, nil, nil, "Space", nil, nil, nil, "Alt", "Fn", "Menu", "Ctrl", nil,
             "←", "↓", "→", "0", nil, ".", nil],
        ]
        return KeyLayout(labels: rows.flatMap { $0 })
    }()
}
