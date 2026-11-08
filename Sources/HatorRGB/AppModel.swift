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
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state: StoredState {
        didSet {
            guard state != oldValue else { return }
            save()
            if state.remapEnabled != oldValue.remapEnabled || state.fKeys != oldValue.fKeys {
                applyRemap()
            }
            let lightingChanged = state.mode != oldValue.mode || state.effect != oldValue.effect
                || state.perKey != oldValue.perKey || state.perKeyBrightness != oldValue.perKeyBrightness
            if lightingChanged && !ledOverride { scheduleApply() }
        }
    }
    @Published private(set) var connected = false
    @Published var lastError: String?
    /// While true (calibration, games), a view drives the LEDs directly via `showFrame`.
    @Published var ledOverride = false

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
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in try? KeyRemapper.clear() } // give the keys back when the app quits
    }

    func applyRemap() {
        guard connected else { return }
        do {
            try KeyRemapper.apply(state.remapEnabled ? state.fKeys : nil)
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

    func applyNow() {
        guard connected else { return }
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
