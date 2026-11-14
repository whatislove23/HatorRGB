import AppKit
import SwiftUI
import ApplicationServices
import HatorKit

/// Modifier keys of a shortcut.
struct Mods: OptionSet, Hashable {
    let rawValue: Int
    static let cmd = Mods(rawValue: 1), shift = Mods(rawValue: 2), opt = Mods(rawValue: 4), ctrl = Mods(rawValue: 8)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ f: CGEventFlags) {
        var m: Mods = []
        if f.contains(.maskCommand) { m.insert(.cmd) }
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskAlternate) { m.insert(.opt) }
        if f.contains(.maskControl) { m.insert(.ctrl) }
        self = m
    }

    /// AXMenuItemCmdModifiers: 0 = ⌘ only; bit 0 ⇧, bit 1 ⌥, bit 2 ⌃, bit 3 "no ⌘".
    init(axMask m: Int) {
        var r: Mods = m & 8 == 0 ? .cmd : []
        if m & 1 != 0 { r.insert(.shift) }
        if m & 2 != 0 { r.insert(.opt) }
        if m & 4 != 0 { r.insert(.ctrl) }
        self = r
    }

    /// Worth showing an overlay for: at least one of ⌘ ⌥ ⌃ (⇧ alone would light every letter).
    var isChord: Bool { !intersection([.cmd, .opt, .ctrl]).isEmpty }
}

/// One keyboard shortcut from an app's menu bar.
struct MenuShortcut: Hashable {
    var key: String       // KeyLayout label: "C", "↑", "F5", "Space"…
    var mods: Mods
    var menu: Int         // index of the top-level menu it lives in (colour group)
    var menuTitle: String
    var title: String
    var shiftImplied: Bool // typed as a shifted symbol ("?", "+"), so ⇧ may or may not be held

    func matches(_ held: Mods) -> Bool { mods == held || (shiftImplied && mods.union(.shift) == held) }

    /// "⇧⌘N"
    var display: String {
        var s = ""
        if mods.contains(.ctrl) { s += "⌃" }
        if mods.contains(.opt) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.cmd) { s += "⌘" }
        return s + key
    }
}

/// Reads the frontmost app's menu bar shortcuts through the Accessibility API.
enum MenuShortcutReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Slow-ish (tens to hundreds of ms for big apps): call off the main thread.
    static func read(pid: pid_t) -> [MenuShortcut] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar: AXUIElement = attr(app, kAXMenuBarAttribute) else { return [] }
        var out: [MenuShortcut] = []
        for (i, top) in children(bar).enumerated() {
            let name: String = attr(top, kAXTitleAttribute) ?? ""
            collect(top, menu: i, menuTitle: name, depth: 0, into: &out)
        }
        return out
    }

    private static func collect(_ el: AXUIElement, menu: Int, menuTitle: String, depth: Int,
                                into out: inout [MenuShortcut]) {
        guard depth < 6 else { return }
        if let s = shortcut(el, menu: menu, menuTitle: menuTitle) { out.append(s) }
        for c in children(el) { collect(c, menu: menu, menuTitle: menuTitle, depth: depth + 1, into: &out) }
    }

    private static func shortcut(_ el: AXUIElement, menu: Int, menuTitle: String) -> MenuShortcut? {
        let glyph: NSNumber? = attr(el, kAXMenuItemCmdGlyphAttribute)
        let char: String? = attr(el, kAXMenuItemCmdCharAttribute)
        var key: String?
        var shiftImplied = false
        if let g = glyph?.intValue, g != 0, let k = glyphs[g] {
            key = k
        } else if let c = char, let first = c.unicodeScalars.first {
            (key, shiftImplied) = mapChar(first)
        }
        guard let key else { return nil }
        let mask: NSNumber? = attr(el, kAXMenuItemCmdModifiersAttribute)
        let title: String = attr(el, kAXTitleAttribute) ?? ""
        return MenuShortcut(key: key, mods: Mods(axMask: mask?.intValue ?? 0), menu: menu,
                            menuTitle: menuTitle, title: title, shiftImplied: shiftImplied)
    }

    private static let shifted: [Character: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]
    private static let plain = Set("`-=[]\\;',./")

    private static func mapChar(_ u: Unicode.Scalar) -> (String?, Bool) {
        switch u.value {
        case 0xF700: return ("↑", false)
        case 0xF701: return ("↓", false)
        case 0xF702: return ("←", false)
        case 0xF703: return ("→", false)
        case 0xF704...0xF70F: return ("F\(u.value - 0xF704 + 1)", false)
        case 0xF728: return ("Del", false)
        case 0xF729: return ("Home", false)
        case 0xF72B: return ("End", false)
        case 0xF72C: return ("PgUp", false)
        case 0xF72D: return ("PgDn", false)
        case 0x08, 0x7F: return ("⌫", false)
        case 0x0D, 0x03: return ("Enter", false)
        case 0x09: return ("Tab", false)
        case 0x1B: return ("Esc", false)
        case 0x20: return ("Space", false)
        default: break
        }
        let ch = Character(u)
        if ch.isLetter, ch.isASCII { return (ch.uppercased(), false) }
        if ch.isNumber, ch.isASCII { return (String(ch), false) }
        if plain.contains(ch) { return (String(ch), false) }
        if let base = shifted[ch] { return (base, true) }
        return (nil, false)
    }

    /// Carbon menu glyph codes for keys that have no character.
    private static let glyphs: [Int: String] = [
        2: "Tab", 4: "Enter", 9: "Space", 10: "Del", 11: "Enter", 13: "Enter", 23: "⌫", 27: "Esc",
        98: "PgUp", 100: "←", 101: "→", 102: "Home", 104: "↑", 105: "End", 106: "↓", 107: "PgDn",
        111: "F1", 112: "F2", 113: "F3", 114: "F4", 115: "F5", 116: "F6", 117: "F7", 118: "F8",
        119: "F9", 120: "F10", 121: "F11", 122: "F12",
    ]

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        attr(el, kAXChildrenAttribute) ?? []
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }
}

enum HotkeyOverlay {
    /// One colour per top-level menu (app menu, File, Edit, View, …).
    static let palette: [RGB] = [
        RGB(255, 200, 0), RGB(0, 136, 255), RGB(40, 220, 90), RGB(170, 60, 255),
        RGB(255, 60, 60), RGB(0, 220, 220), RGB(255, 120, 0), RGB(255, 60, 200),
    ]

    /// Keys with a shortcut for the held modifiers, coloured by menu; the held modifier keys white.
    static func frame(_ shortcuts: [MenuShortcut], held: Mods, layout: KeyLayout, swapWinAlt: Bool) -> [RGB] {
        var byKey: [String: Int] = [:]
        for s in shortcuts where s.matches(held) {
            byKey[s.key] = min(byKey[s.key] ?? .max, s.menu)
        }
        var modLabels: Set<String> = []
        if held.contains(.cmd) { modLabels.insert(swapWinAlt ? "Alt" : "Win") }
        if held.contains(.opt) { modLabels.insert(swapWinAlt ? "Win" : "Alt") }
        if held.contains(.ctrl) { modLabels.insert("Ctrl") }
        if held.contains(.shift) { modLabels.insert("⇧") }
        return layout.labels.map { label in
            guard let label else { return .black }
            if modLabels.contains(label) { return .white }
            if let menu = byKey[label] { return palette[menu % palette.count] }
            return .black
        }
    }
}

/// On-screen legend shown while the overlay is up: what each lit key does, grouped by menu
/// in the same colours as on the keyboard. A non-activating panel, so it never steals focus.
@MainActor
final class HotkeyLegend {
    static let shared = HotkeyLegend()
    private var panel: NSPanel?

    func show(_ shortcuts: [MenuShortcut], held: Mods) {
        var seen = Set<String>()
        let items = shortcuts.filter { $0.matches(held) && !$0.title.isEmpty && seen.insert($0.display + $0.title).inserted }
        guard !items.isEmpty else { hide(); return }
        let groups = Dictionary(grouping: items, by: \.menu).sorted { $0.key < $1.key }
            .map { LegendGroup(menu: $0.key, title: $0.value[0].menuTitle, items: $0.value) }
        let host = NSHostingView(rootView: LegendView(groups: groups))
        let size = host.fittingSize
        let p = panel ?? makePanel()
        p.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 40, width: size.width, height: size.height),
                       display: true)
        }
        p.orderFrontRegardless()
        panel = p
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }
}

struct LegendGroup: Identifiable {
    var menu: Int
    var title: String
    var items: [MenuShortcut]
    var id: Int { menu }
}

private struct LegendView: View {
    let groups: [LegendGroup]

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            ForEach(columns, id: \.first!.id) { column in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(column) { g in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle().fill(HotkeyOverlay.palette[g.menu % HotkeyOverlay.palette.count].color)
                                    .frame(width: 9, height: 9)
                                Text(g.title).font(.caption.bold()).foregroundStyle(.secondary)
                            }
                            ForEach(g.items.prefix(14), id: \.self) { s in
                                HStack(spacing: 8) {
                                    Text(s.display).font(.system(.callout, design: .monospaced).bold())
                                        .frame(minWidth: 56, alignment: .trailing)
                                    Text(s.title).font(.callout).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }

    /// Splits menu groups into up to 4 columns of roughly equal height.
    private var columns: [[LegendGroup]] {
        let total = groups.reduce(0) { $0 + min($1.items.count, 14) + 2 }
        let target = max(10, total / 4 + 1)
        var cols: [[LegendGroup]] = [[]]
        var h = 0
        for g in groups {
            let gh = min(g.items.count, 14) + 2
            if h + gh > target, !cols[cols.count - 1].isEmpty { cols.append([]); h = 0 }
            cols[cols.count - 1].append(g)
            h += gh
        }
        return cols
    }
}
