import SwiftUI
import AppKit
import ServiceManagement
import HatorKit
import os

let hotkeyLog = Logger(subsystem: "local.hatorrgb", category: "hotkeys")

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
    /// Hold ⌘/⌥/⌃ to light the keys that have shortcuts in the frontmost app.
    var hotkeyOverlay = false
    /// In per-key mode, light the media keys (F7–F12 by default) white while music plays.
    var mediaKeysGlow = true
    /// Equaliser bars on the keyboard while the Mac plays sound.
    var visualizer = false
    var visualizerStyle = VisualizerStyle.pulse

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
        hotkeyOverlay = try c.decodeIfPresent(Bool.self, forKey: .hotkeyOverlay) ?? d.hotkeyOverlay
        mediaKeysGlow = try c.decodeIfPresent(Bool.self, forKey: .mediaKeysGlow) ?? d.mediaKeysGlow
        visualizer = try c.decodeIfPresent(Bool.self, forKey: .visualizer) ?? d.visualizer
        visualizerStyle = try c.decodeIfPresent(VisualizerStyle.self, forKey: .visualizerStyle) ?? d.visualizerStyle
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
                || state.mediaKeysGlow != oldValue.mediaKeysGlow || state.fKeys != oldValue.fKeys
                || state.remapEnabled != oldValue.remapEnabled
            if state.badgeApps != oldValue.badgeApps {
                let on = Set(state.badgeApps.filter(\.enabled).map(\.id))
                badgeAlerts = badgeAlerts.filter { on.contains($0.key) }
                badgeAck = badgeAck.filter { on.contains($0.key) }
            }
            if lightingChanged && !ledOverride { scheduleApply() }
            if state.hotkeyOverlay != oldValue.hotkeyOverlay { updateHotkeyWatch() }
            if state.visualizer != oldValue.visualizer { updateVisualizer() }
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
    private var lastAnimColor = RGB.black

    /// Hotkey overlay: Accessibility permission granted (refreshed every second).
    @Published private(set) var axTrusted = MenuShortcutReader.isTrusted
    private var hotkeyTimer: Timer?
    private var heldMods: Mods = []
    private var heldSince = Date()
    /// Modifiers the overlay currently shows; nil = overlay off.
    private var overlayShown: Mods?
    private var shortcutCache: [pid_t: (read: Date, items: [MenuShortcut])] = [:]
    private var readingPids: Set<pid_t> = []

    /// System Now Playing state, checked every second.
    @Published private(set) var music: NowPlaying.State = .none

    /// Visualizer: audio tap (macOS 14.2+), analyzer, frame timer; `visualizerShowing` = bars on screen now.
    private var audioTap: AnyObject?
    private var analyzer = SpectrumAnalyzer(bands: VisualizerFrame.columns)
    private var visualizerTimer: Timer?
    private var visualizerShowing = false
    private var lastSound = Date.distantPast
    /// A frame takes ~45 ms to send (9 reports × ~5 ms), so frames go out on their own queue,
    /// one at a time, always the newest: ~20 fps without blocking the UI.
    private let frameQueue = DispatchQueue(label: "local.hatorrgb.frames", qos: .userInteractive)
    private var frameBusy = false
    private var lastFrame: [RGB] = []
    private var lastFrameSent = Date.distantPast
    private let pulse = PulseStyle()
    private var lastPulse = RGB.black
    static var visualizerSupported: Bool { if #available(macOS 14.2, *) { true } else { false } }

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
                self?.checkMusic()
                if let self, self.axTrusted != MenuShortcutReader.isTrusted {
                    self.axTrusted.toggle()
                    self.updateHotkeyWatch()
                }
            }
        }
        // Pre-read the menu shortcuts of whichever app comes to the front.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid, self.hotkeyTimer != nil else { return }
                self.readShortcuts(pid: pid)
            }
        }
        updateHotkeyWatch()
        updateVisualizer()
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
        guard connected, overlayShown == nil, !visualizerShowing else { return }
        if !alertColors.isEmpty { startAlertAnimation(); return }
        stopAlertAnimation()
        do {
            switch state.mode {
            case .effect: try device.apply(state.effect)
            case .perKey: try device.applyPerKey(perKeyFrame, brightness: state.perKeyBrightness)
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: Visualizer

    private func updateVisualizer() {
        guard #available(macOS 14.2, *) else { return }
        if state.visualizer, audioTap == nil {
            let tap = SystemAudioTap()
            do {
                try tap.start()
            } catch {
                lastError = "\(error)"
                return
            }
            audioTap = tap
            visualizerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.visualizerTick() }
            }
        } else if !state.visualizer, let tap = audioTap as? SystemAudioTap {
            tap.stop()
            audioTap = nil
            visualizerTimer?.invalidate()
            visualizerTimer = nil
            if visualizerShowing { visualizerShowing = false; restoreAfterFrames() }
        }
    }

    /// Hands the LEDs back once any frame still being sent has finished.
    private func restoreAfterFrames() {
        lastFrame = []
        lastPulse = .black
        frameQueue.async {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if !self.ledOverride { self.applyNow() } }
            }
        }
    }

    private func visualizerTick() {
        guard #available(macOS 14.2, *), let tap = audioTap as? SystemAudioTap else { return }
        // Alerts and the hotkey overlay take priority.
        guard connected, !ledOverride, overlayShown == nil, alertColors.isEmpty else {
            lastFrame = []
            if visualizerShowing { visualizerShowing = false; restoreAfterFrames() }
            return
        }
        guard !frameBusy else { return }
        let heights = analyzer.heights(tap.latest(2048), sampleRate: tap.sampleRate)
        if heights != nil { lastSound = Date() }
        // Keep the bars through short pauses; hand back the normal lighting after 1.5 s of silence.
        guard Date().timeIntervalSince(lastSound) < 1.5 else {
            if visualizerShowing { visualizerShowing = false; restoreAfterFrames() }
            return
        }
        visualizerShowing = true
        let device = self.device
        switch state.visualizerStyle {
        case .pulse:
            // One static-colour report per frame. The keyboard's controller also scans the keys, so
            // LED traffic is capped (~20 reports/s, only real changes) or typing starts to drop keys.
            let color = pulse.color(heights)
            guard Date().timeIntervalSince(lastFrameSent) >= 0.05,
                  max(abs(Int(color.r) - Int(lastPulse.r)), abs(Int(color.g) - Int(lastPulse.g)),
                      abs(Int(color.b) - Int(lastPulse.b))) > 4 else { return }
            lastPulse = color
            lastFrameSent = Date()
            var s = EffectSettings()
            s.effect = .staticColor
            s.brightness = 4
            s.rainbow = false
            s.foreground = color
            lastFrame = []
            frameBusy = true
            frameQueue.async {
                try? device.apply(s)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.frameBusy = false } }
            }
        case .bars:
            // Per-key frames are slow on this firmware and busy the controller that also scans the keys:
            // whole cells, at most ~10 fps, changed messages only.
            guard Date().timeIntervalSince(lastFrameSent) >= 0.1 else { return }
            let frame = VisualizerFrame.render(heights ?? Array(repeating: 0, count: VisualizerFrame.columns),
                                               layout: state.layout)
            guard frame != lastFrame else { return }
            let previous = lastFrame
            lastFrame = frame
            lastFrameSent = Date()
            frameBusy = true
            frameQueue.async {
                // First frame switches to per-key mode; after that only changed messages are sent.
                if previous.count == frame.count {
                    try? device.updatePerKey(frame, from: previous)
                } else {
                    try? device.applyPerKey(frame, brightness: 4)
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.frameBusy = false } }
            }
        }
    }

    // MARK: Media keys

    private static let mediaActions: Set<KeyAction> = [.previousTrack, .playPause, .nextTrack, .mute, .volumeDown, .volumeUp]

    /// LED slots of the F-keys mapped to playback / volume, with the action of each.
    private var mediaSlots: [(slot: Int, action: KeyAction)] {
        guard state.remapEnabled else { return [] }
        var byLabel: [String: KeyAction] = [:]
        for (i, a) in state.fKeys.actions.enumerated() where Self.mediaActions.contains(a) { byLabel["F\(i + 1)"] = a }
        return state.layout.labels.enumerated().compactMap { i, label in
            label.flatMap { byLabel[$0] }.map { (i, $0) }
        }
    }

    /// While a player is open (per-key mode): media keys white, play/pause green (playing) or red (paused).
    private var mediaKeyColors: [(slot: Int, color: RGB)] {
        guard state.mode == .perKey, state.mediaKeysGlow, music != .none else { return [] }
        return mediaSlots.map { slot, action in
            (slot, action == .playPause ? (music == .playing ? RGB(0, 255, 0) : RGB(255, 0, 0)) : .white)
        }
    }

    /// The per-key colours to send: the user's, with the media keys on top.
    private var perKeyFrame: [RGB] {
        var colors = state.perKey
        for (slot, color) in mediaKeyColors where colors.indices.contains(slot) { colors[slot] = color }
        return colors
    }

    private func checkMusic() {
        guard state.mediaKeysGlow, state.mode == .perKey else {
            if music != .none { music = .none }
            return
        }
        NowPlaying.check { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, now != self.music else { return }
                self.music = now
                self.refreshLighting()
            }
        }
    }

    // MARK: Alert pulse

    /// One breath (dark → full → dark) per colour; colours take turns, one per breath.
    private static let breathPeriod: TimeInterval = 2.4

    /// Drives the pulse from the Mac (static colour frames at 40 fps) so each breath can use a different colour.
    private func startAlertAnimation() {
        guard animTimer == nil else { return }
        animStart = Date()
        lastAnimColor = RGB(1, 1, 1)
        animCycle = -1
        animColorIndex = 0
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animationTick() }
        }
    }

    private func stopAlertAnimation() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func animationTick() {
        let colors = alertColors
        guard connected, !ledOverride, overlayShown == nil, !colors.isEmpty else { return }
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
        let pulse = RGB(ch(c.r), ch(c.g), ch(c.b))
        var s = EffectSettings()
        s.effect = .staticColor
        s.brightness = 4
        s.foreground = pulse
        s.rainbow = false
        guard pulse != lastAnimColor else { return }
        lastAnimColor = pulse
        try? device.apply(s)
    }

    // MARK: Hotkey overlay

    func enableHotkeyOverlay(_ on: Bool) {
        if on && !MenuShortcutReader.isTrusted { MenuShortcutReader.requestAccess() }
        state.hotkeyOverlay = on
    }

    /// Polls the modifier state (20×/s, no permission needed) while the feature is on and allowed.
    private func updateHotkeyWatch() {
        let want = state.hotkeyOverlay && axTrusted
        if want, hotkeyTimer == nil {
            hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.hotkeyTick() }
            }
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { readShortcuts(pid: pid) }
        } else if !want, let t = hotkeyTimer {
            t.invalidate()
            hotkeyTimer = nil
            hideOverlay()
        }
    }

    private func hotkeyTick() {
        let held = Mods(CGEventSource.flagsState(.combinedSessionState))
        guard held.isChord, connected, !ledOverride,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            heldMods = []
            hideOverlay()
            return
        }
        if held != heldMods {
            heldMods = held
            heldSince = Date()
            if shortcutCache[pid].map({ Date().timeIntervalSince($0.read) > 5 }) ?? true { readShortcuts(pid: pid) }
        }
        // Short delay so ordinary ⌘C / ⌘V don't flash the keyboard.
        guard Date().timeIntervalSince(heldSince) >= 0.35, overlayShown != held,
              let items = shortcutCache[pid]?.items else { return }
        overlayShown = held
        hotkeyLog.debug("overlay mods=\(held.rawValue, privacy: .public) items=\(items.count, privacy: .public)")
        let frame = HotkeyOverlay.frame(items, held: held, layout: state.layout, swapWinAlt: state.swapWinAlt)
        try? device.applyPerKey(frame, brightness: 4)
        HotkeyLegend.shared.show(items, held: held)
    }

    private func hideOverlay() {
        guard overlayShown != nil else { return }
        overlayShown = nil
        visualizerShowing = false
        lastFrame = []
        HotkeyLegend.shared.hide()
        applyNow()
    }

    private func readShortcuts(pid: pid_t) {
        guard !readingPids.contains(pid) else { return }
        readingPids.insert(pid)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = MenuShortcutReader.read(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.readingPids.remove(pid)
                    hotkeyLog.debug("read \(items.count, privacy: .public) shortcuts from pid \(pid, privacy: .public)")
                    self.shortcutCache[pid] = (Date(), items)
                    // Drop apps that have quit.
                    let alive = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
                    self.shortcutCache = self.shortcutCache.filter { alive.contains($0.key) }
                    if self.overlayShown != nil { self.overlayShown = []; self.hotkeyTick() } // redraw with fresh data
                }
            }
        }
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
