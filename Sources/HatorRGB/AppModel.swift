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
                || state.claudeAlert != oldValue.claudeAlert
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
                if fresh.count != self.claudeWaiting.count { self.claudeWaiting = fresh; self.refreshLighting() }
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
        let wasActive = claudeAlertActive
        if waiting { claudeWaiting[session] = claudeWaiting[session] ?? Date() } else { claudeWaiting[session] = nil }
        if claudeAlertActive != wasActive { refreshLighting() }
    }

    func clearClaudeAlert() {
        claudeWaiting = [:]
        refreshLighting()
    }

    private func refreshLighting() {
        if !ledOverride { applyNow() }
    }

    /// Soft orange pulse using the keyboard's own breathe effect (smooth, no CPU).
    static let claudePulse: EffectSettings = {
        var s = EffectSettings()
        s.effect = .breathe
        s.foreground = RGB(255, 90, 0)
        s.background = .black
        s.brightness = 4
        s.speed = 1
        s.rainbow = false
        return s
    }()

    func applyNow() {
        guard connected else { return }
        do {
            if claudeAlertActive {
                try device.apply(Self.claudePulse)
                lastError = nil
                return
            }
            switch state.mode {
            case .effect: try device.apply(state.effect)
            case .perKey: try device.applyPerKey(state.perKey, brightness: state.perKeyBrightness)
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
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
