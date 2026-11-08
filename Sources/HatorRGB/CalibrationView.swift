import SwiftUI
import AppKit
import HatorKit

/// Walks through all 132 LED slots: lights one white, the user presses that key (or skips).
struct CalibrationView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var slot = 0
    @State private var labels: [String?] = []
    @State private var monitor: Any?

    private var total: Int { HatorProtocol.slotCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Калібрування розкладки").font(.title3.bold())
            ProgressView(value: Double(slot), total: Double(total))
            Text("Слот \(slot + 1) з \(total) (ряд \(slot / HatorProtocol.columns + 1), колонка \(slot % HatorProtocol.columns + 1))")
                .foregroundStyle(.secondary)
            Text("Натисни клавішу, яка зараз світиться **білим**. Якщо нічого не світиться — «Пропустити».")
            HStack {
                Text("Поточна назва:").foregroundStyle(.secondary)
                Text(labels.indices.contains(slot) ? (labels[slot] ?? "—") : "—").bold()
            }
            HStack {
                Button("← Назад") { go(to: slot - 1) }.disabled(slot == 0)
                Button("Пропустити (не світиться)") { assign(nil) }
                Button("Світиться Fn") { assign("Fn") }
                    .help("Fn та деякі системні клавіші неможливо зчитати — познач вручну")
                Spacer()
                Button("Скасувати") { finish(save: false) }
                Button("Зберегти") { finish(save: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        labels = model.state.layout.labels
        model.ledOverride = true
        go(to: 0)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown, event.keyCode == 36, event.modifierFlags.contains(.command) {
                return event // ⌘↩ still triggers "Save"
            }
            if event.type == .flagsChanged && !Self.isModifierPress(event) { return nil }
            assign(KeyNames.name(for: event))
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.ledOverride = false
        model.applyNow()
    }

    private func go(to s: Int) {
        slot = max(0, min(total - 1, s))
        model.lightOnly(slot: slot)
    }

    private func assign(_ label: String?) {
        guard labels.indices.contains(slot) else { return }
        labels[slot] = label
        if slot == total - 1 { finish(save: true) } else { go(to: slot + 1) }
    }

    private func finish(save: Bool) {
        if save { model.state.layout.labels = labels }
        dismiss()
    }

    private static func isModifierPress(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags
        switch e.keyCode {
        case 56, 60: return f.contains(.shift)
        case 59, 62: return f.contains(.control)
        case 58, 61: return f.contains(.option)
        case 55, 54: return f.contains(.command)
        case 57: return true // Caps Lock toggles: one event per press
        case 63: return f.contains(.function)
        default: return false
        }
    }
}

enum KeyNames {
    static let table: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "§", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "Enter", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "⌫", 53: "Esc",
        54: "Win", 55: "Win", 56: "⇧", 57: "Caps", 58: "Alt", 59: "Ctrl", 60: "⇧", 61: "Alt", 62: "Ctrl",
        63: "Fn", 65: ".", 67: "*", 69: "+", 71: "Num", 75: "/", 76: "↵", 78: "−", 81: "=",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "PrtSc",
        107: "ScrLk", 109: "F10", 110: "Menu", 111: "F12", 113: "Pause", 114: "Ins", 115: "Home",
        116: "PgUp", 117: "Del", 118: "F4", 119: "End", 120: "F2", 121: "PgDn", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for e: NSEvent) -> String {
        if let n = table[e.keyCode] { return n }
        if e.type == .keyDown, let c = e.charactersIgnoringModifiers?.uppercased(), !c.isEmpty,
           c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return c
        }
        return "#\(e.keyCode)"
    }
}
