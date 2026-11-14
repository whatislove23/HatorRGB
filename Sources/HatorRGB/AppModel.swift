import SwiftUI
import AppKit
import ServiceManagement
import HatorKit

enum LightMode: String, Codable { case effect, perKey }

struct Preset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var colors: [RGB]
}

/// An app whose Dock badge (unread counter) lights up the keyboard.
struct BadgeApp: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bundleIDs: [String]
    var color: RGB
    var enabled: Bool

    static let defaults = [
        BadgeApp(id: "telegram", name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"],
                 color: RGB(0, 136, 255), enabled: true),
        BadgeApp(id: "slack", name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"],
                 color: RGB(224, 30, 90), enabled: false),
        BadgeApp(id: "mail", name: "Пошта", bundleIDs: ["com.apple.mail"],
                 color: RGB(60, 220, 120), enabled: false),
    ]
}

struct StoredState: Codable, Equatable {
    var mode: LightMode = .effect
    var effect = EffectSettings()
    var perKey = Array(repeating: RGB(0, 120, 255), count: HatorProtocol.slotCount)
    var perKeyBrightness: UInt8 = 4
    var layout = KeyLayout.default
    var presets: [Preset] = []
    var remapEnabled = true
    var fKeys = FKeyMapping.macBook
    /// ⌘ next to the space bar (Win ↔ Alt). Starts from what System Settings has.
    var swapWinAlt = KeyRemapper.systemSwapsWinAlt()
    /// Pulse the keyboard orange while a Claude Code session waits for the user.
    var claudeAlert = true
    /// Apps whose new unread messages pulse the keyboard in their colour.
    var badgeApps = BadgeApp.defaults

    init() {}
    // Tolerate state saved by older versions (missing keys fall back to defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StoredState()
        mode = try c.decodeIfPresent(LightMode.self, forKey: .mode) ?? d.mode
        effect = try c.decodeIfPresent(EffectSettings.self, forKey: .effect) ?? d.effect
        perKey = try c.decodeIfPresent([RGB].self, forKey: .perKey) ?? d.perKey
        perKeyBrightness = try c.decodeIfPresent(UInt8.self, forKey: .perKeyBrightness) ?? d.perKeyBrightness
        layout = try c.decodeIfPresent(KeyLayout.self, forKey: .layout) ?? d.layout
        presets = try c.decodeIfPresent([Preset].self, forKey: .presets) ?? d.presets
        remapEnabled = try c.decodeIfPresent(Bool.self, forKey: .remapEnabled) ?? d.remapEnabled
        fKeys = try c.decodeIfPresent(FKeyMapping.self, forKey: .fKeys) ?? d.fKeys
        swapWinAlt = try c.decodeIfPresent(Bool.self, forKey: .swapWinAlt) ?? d.swapWinAlt
        claudeAlert = try c.decodeIfPresent(Bool.self, forKey: .claudeAlert) ?? d.claudeAlert
        badgeApps = try c.decodeIfPresent([BadgeApp].self, forKey: .badgeApps) ?? d.badgeApps
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state: StoredState {
        didSet {
            guard state != oldValue else { return }
            save()
            if state.remapEnabled != oldValue.remapEnabled || state.fKeys != oldValue.fKeys
                || state.swapWinAlt != oldValue.swapWinAlt {
                applyRemap()
            }
            let lightingChanged = state.mode != oldValue.mode || state.effect != oldValue.effect
                || state.perKey != oldValue.perKey || state.perKeyBrightness != oldValue.perKeyBrightness
                || state.claudeAlert != oldValue.claudeAlert || state.badgeApps != oldValue.badgeApps
            if state.badgeApps != oldValue.badgeApps {
                let on = Set(state.badgeApps.filter(\.enabled).map(\.id))
                badgeAlerts = badgeAlerts.filter { on.contains($0.key) }
                badgeAck = badgeAck.filter { on.contains($0.key) }
            }
            if lightingChanged && !ledOverride { scheduleApply() }
        }
    }
    @Published private(set) var connected = false
    @Published var lastError: String?
    /// While true (calibration, games), a view drives the LEDs directly via `showFrame`.
    @Published var ledOverride = false
    /// Claude Code sessions currently waiting for the user, with when they started waiting.
    @Published private(set) var claudeWaiting: [String: Date] = [:]
    var claudeAlertActive: Bool { state.claudeAlert && !claudeWaiting.isEmpty }
    private static let claudeStaleAfter: TimeInterval = 2 * 60 * 60
    private var focusWatch: Timer?

    /// Badge apps with unread messages you haven't looked at yet (app id → since when).
    @Published private(set) var badgeAlerts: [String: Date] = [:]
    /// Current badge count per app id (0 = none or not running).
    @Published private(set) var badgeCounts: [String: Int] = [:]
    /// Count already seen per app; only a higher count raises the alert again.
    private var badgeAck: [String: Int] = [:]
    private var badgePolling = false

    /// Colours to pulse, in turn: Claude first, then badge apps in menu order.
    var alertColors: [RGB] {
        var colors: [RGB] = claudeAlertActive ? [Self.claudeColor] : []
        colors += state.badgeApps.filter { $0.enabled && badgeAlerts[$0.id] != nil }.map(\.color)
        return colors
    }
    static let claudeColor = RGB(255, 90, 0)
    private var animTimer: Timer?
    private var animStart = Date()
    private var animCycle = -1
    private var animColorIndex = 0

    /// Apps where you talk to Claude: the desktop app, terminals and editors with Claude Code.
    static let claudeApps: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty", "dev.zed.Zed",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]

    private let device = HatorDevice()
    private var pending: Task<Void, Never>?
    private static let defaultsKey = "state.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let s = try? JSONDecoder().decode(StoredState.self, from: data) {
            state = s
        } else {
            state = StoredState()
        }
        device.onConnectionChange = { [weak self] isOn in
            MainActor.assumeIsolated { self?.connectionChanged(isOn) }
        }
        connected = device.isConnected
        if connected { applyNow(); applyRemap() }
        DistributedNotificationCenter.default().addObserver(
            forName: ClaudeSignal.name, object: nil, queue: .main
        ) { [weak self] note in
            let session = note.object as? String ?? "default"
            let wait = (note.userInfo?["state"] as? String) == ClaudeSignal.State.wait.rawValue
            MainActor.assumeIsolated { self?.claudeSignal(session: session, waiting: wait) }
        }
        // Forget sessions that never reported back (crashed / closed without SessionEnd).
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fresh = self.claudeWaiting.filter { Date().timeIntervalSince($0.value) < Self.claudeStaleAfter }
                if fresh.count != self.claudeWaiting.count {
                    self.claudeWaiting = fresh; self.refreshLighting()
                }
            }
        }
        // Once a second: read Dock badges and check whether you've come back to an alerting app.
        focusWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollBadges()
                self?.checkUserBack()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in try? KeyRemapper.clear() } // on quit, hand the keys back to System Settings' config
    }

    func applyRemap() {
        guard connected else { return }
        do {
            try KeyRemapper.apply(state.remapEnabled ? state.fKeys : nil, swapWinAlt: state.swapWinAlt)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func connectionChanged(_ isOn: Bool) {
        connected = isOn
        guard isOn else { return }
        applyRemap()
        // Give the firmware a moment after enumeration, then restore our lighting.
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, !self.ledOverride else { return }
            self.applyNow()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Coalesces rapid changes (sliders, colour wells, painting) into one write.
    private func scheduleApply() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            self?.applyNow()
        }
    }

    private func claudeSignal(session: String, waiting: Bool) {
        let before = alertColors
        if waiting { claudeWaiting[session] = claudeWaiting[session] ?? Date() } else { claudeWaiting[session] = nil }
        if alertColors != before { refreshLighting() }
    }

    /// Reads the Dock badges of enabled apps off the main thread.
    private func pollBadges() {
        let apps = state.badgeApps.filter(\.enabled)
        guard !apps.isEmpty, !badgePolling else {
            if apps.isEmpty && !badgeCounts.isEmpty { badgeCounts = [:] }
            return
        }
        let running = NSWorkspace.shared.runningApplications
        let targets: [(String, pid_t)] = apps.compactMap { app in
            running.first { app.bundleIDs.contains($0.bundleIdentifier ?? "") }.map { (app.id, $0.processIdentifier) }
        }
        badgePolling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var counts: [String: Int] = [:]
            for (id, pid) in targets { counts[id] = BadgeReader.count(pid: pid) ?? 0 }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.badgePolling = false
                    self?.badgesRead(counts, apps: apps.map(\.id))
                }
            }
        }
    }

    private func badgesRead(_ counts: [String: Int], apps: [String]) {
        let before = alertColors
        for id in apps {
            let count = counts[id] ?? 0
            guard let ack = badgeAck[id] else { badgeAck[id] = count; continue } // unread from before launch: no alert
            if count == 0 {
                badgeAlerts[id] = nil
                badgeAck[id] = 0
            } else if count < ack {
                badgeAck[id] = count
            } else if count > ack, badgeAlerts[id] == nil {
                badgeAlerts[id] = Date()
            }
        }
        if counts != badgeCounts { badgeCounts = counts }
        if alertColors != before { refreshLighting() }
    }

    /// You're back with an alerting app when it's frontmost and you've pressed a key or used the mouse
    /// since the alert started. Uses the system idle counter, so no Input Monitoring permission is needed.
    private func checkUserBack() {
        guard !claudeWaiting.isEmpty || !badgeAlerts.isEmpty,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let lastInput = Date().addingTimeInterval(-idle)
        let before = alertColors
        if Self.claudeApps.contains(front) {
            for (key, since) in claudeWaiting where since < lastInput { claudeWaiting[key] = nil }
        }
        for app in state.badgeApps where app.bundleIDs.contains(front) {
            if let since = badgeAlerts[app.id], since < lastInput {
                badgeAlerts[app.id] = nil
                badgeAck[app.id] = badgeCounts[app.id] ?? 0
            }
        }
        if alertColors != before { refreshLighting() }
    }

    func clearClaudeAlert() {
        claudeWaiting = [:]
        refreshLighting()
    }

    func clearBadgeAlerts() {
        for id in badgeAlerts.keys { badgeAck[id] = badgeCounts[id] ?? 0 }
        badgeAlerts = [:]
        refreshLighting()
    }

    private func refreshLighting() {
        if !ledOverride { applyNow() }
    }

    func applyNow() {
        guard connected else { return }
        if !alertColors.isEmpty { startAlertAnimation(); return }
        stopAlertAnimation()
        do {
            switch state.mode {
            case .effect: try device.apply(state.effect)
            case .perKey: try device.applyPerKey(state.perKey, brightness: state.perKeyBrightness)
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: Alert pulse

    /// One breath (dark → full → dark) per colour; colours take turns, one per breath.
    private static let breathPeriod: TimeInterval = 2.4

    /// Drives the pulse from the Mac (static colour frames at 40 fps) so each breath can use a different colour.
    private func startAlertAnimation() {
        guard animTimer == nil else { return }
        animStart = Date()
        animCycle = -1
        animColorIndex = 0
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 40, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animationTick() }
        }
    }

    private func stopAlertAnimation() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func animationTick() {
        let colors = alertColors
        guard connected, !ledOverride, !colors.isEmpty else { return }
        let t = Date().timeIntervalSince(animStart)
        let cycle = Int(t / Self.breathPeriod)
        if cycle != animCycle {
            if animCycle >= 0 { animColorIndex += 1 }
            animCycle = cycle
        }
        let c = colors[animColorIndex % colors.count]
        let phase = t.truncatingRemainder(dividingBy: Self.breathPeriod) / Self.breathPeriod
        let k = pow(sin(phase * .pi), 2)
        func ch(_ v: UInt8) -> UInt8 { UInt8((Double(v) * k).rounded()) }
        var s = EffectSettings()
        s.effect = .staticColor
        s.brightness = 4
        s.foreground = RGB(ch(c.r), ch(c.g), ch(c.b))
        s.rainbow = false
        try? device.apply(s)
    }

    /// Lights a single LED slot white (all others off) — used by calibration.
    func lightOnly(slot: Int) {
        var colors = Array(repeating: RGB.black, count: HatorProtocol.slotCount)
        if (0..<colors.count).contains(slot) { colors[slot] = .white }
        try? device.applyPerKey(colors, brightness: 4)
    }

    /// Pushes a raw 132-slot frame to the keyboard (custom per-key mode, full brightness).
    func showFrame(_ colors: [RGB]) {
        guard connected else { return }
        try? device.applyPerKey(colors, brightness: 4)
    }

    // MARK: Presets

    func savePreset(named name: String) {
        state.presets.append(Preset(name: name, colors: state.perKey))
    }

    func load(_ preset: Preset) {
        state.mode = .perKey
        state.perKey = preset.colors
    }

    func delete(_ preset: Preset) {
        state.presets.removeAll { $0.id == preset.id }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Автозапуск: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}

extension RGB {
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func c(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(c(ns.redComponent), c(ns.greenComponent), c(ns.blueComponent))
    }

    /// Readable text colour on top of this colour.
    var labelColor: Color {
        let luma = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
        return luma > 140 ? .black : .white
    }
}
