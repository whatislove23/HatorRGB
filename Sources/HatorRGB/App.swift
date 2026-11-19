import SwiftUI
import AppKit
import HatorKit

@main
struct HatorRGBApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.connected ? "keyboard.fill" : "keyboard")
        }
        .menuBarExtraStyle(.window)

        Window("Підсвітка клавіш — HATOR", id: "editor") {
            EditorView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

enum MenuTab: String, CaseIterable, Identifiable {
    case lighting, alerts, music, keys
    var id: Self { self }
    var title: String {
        switch self {
        case .lighting: "Підсвітка"
        case .alerts: "Сигнали"
        case .music: "Музика"
        case .keys: "Клавіші"
        }
    }
    var symbol: String {
        switch self {
        case .lighting: "paintpalette"
        case .alerts: "bell.badge"
        case .music: "waveform"
        case .keys: "command"
        }
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menu.tab") private var tab: MenuTab = .lighting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                Text("HATOR").font(.headline)
                Spacer()
                Circle().fill(model.connected ? .green : .red).frame(width: 7, height: 7)
                Text(model.connected ? "підключено" : "не знайдено")
                    .font(.caption).foregroundStyle(.secondary)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("Вийти")
                    .padding(.leading, 4)
            }

            HStack(spacing: 4) {
                ForEach(MenuTab.allCases) { t in
                    TabButton(tab: t, selected: tab == t) { tab = t }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                switch tab {
                case .lighting: lighting
                case .alerts: alerts
                case .music: Card { VisualizerControls() }
                case .keys: keys
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Гасити, коли Mac спить або заблокований", isOn: $model.state.darkWhenAway)
                    .toggleStyle(.trailingCheckbox)
                Toggle("Запускати при вході", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    .toggleStyle(.trailingCheckbox)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private var lighting: some View {
        Picker("", selection: $model.state.mode) {
            Text("Ефекти").tag(LightMode.effect)
            Text("Поклавішно").tag(LightMode.perKey)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Card {
            if model.state.mode == .effect {
                EffectControls(settings: $model.state.effect)
            } else {
                PerKeyControls(openEditor: openEditor)
            }
        }
    }

    @ViewBuilder private var alerts: some View {
        Card { BadgeAlertControls() }
    }

    @ViewBuilder private var keys: some View {
        Card { HotkeyOverlayControls() }
        Card { FKeyControls() }
    }

    private func openEditor() {
        openWindow(id: "editor")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct TabButton: View {
    let tab: MenuTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol).font(.system(size: 15))
                Text(tab.title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A grouped block of related settings.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EffectControls: View {
    @Binding var settings: EffectSettings

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Ефект")
                Picker("", selection: $settings.effect) {
                    ForEach(Effect.presets) { Text($0.name).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Колір")
                HStack {
                    RGBWell(color: settings.foreground) { [settings = $settings] in settings.wrappedValue.foreground = $0 }
                    if settings.effect.usesBackground {
                        Text("Фон").foregroundStyle(.secondary)
                        RGBWell(color: settings.background) { [settings = $settings] in settings.wrappedValue.background = $0 }
                    }
                    Spacer()
                    if settings.effect != .staticColor {
                        Toggle("Веселка", isOn: $settings.rainbow).toggleStyle(.trailingCheckbox)
                    }
                }
            }
            GridRow {
                Text("Яскравість")
                Slider(value: level(\.brightness), in: 0...4, step: 1)
            }
            if settings.effect.usesSpeed {
                GridRow {
                    Text("Швидкість")
                    Slider(value: level(\.speed), in: 0...4, step: 1)
                }
            }
            if settings.effect.usesDirection {
                GridRow {
                    Text("Напрямок")
                    Picker("", selection: $settings.direction) {
                        ForEach(Direction.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private func level(_ kp: WritableKeyPath<EffectSettings, UInt8>) -> Binding<Double> {
        Binding(get: { Double(settings[keyPath: kp]) }, set: { settings[keyPath: kp] = UInt8($0.rounded()) })
    }
}

struct PerKeyControls: View {
    @EnvironmentObject var model: AppModel
    let openEditor: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: openEditor) {
                Label("Відкрити редактор клавіш", systemImage: "keyboard")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            HStack {
                Text("Яскравість")
                Slider(value: Binding(
                    get: { Double(model.state.perKeyBrightness) },
                    set: { model.state.perKeyBrightness = UInt8($0.rounded()) }), in: 0...4, step: 1)
            }


            if !model.state.presets.isEmpty {
                Text("Пресети").font(.caption).foregroundStyle(.secondary)
                ForEach(model.state.presets) { p in
                    Button(p.name) { model.load(p) }.buttonStyle(.link)
                }
            }
        }
    }
}

struct FKeyControls: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.state.swapWinAlt) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Win ↔ Alt")
                    Text("⌘ біля пробілу, як на Mac").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.trailingSwitch).controlSize(.small)

            Toggle(isOn: $model.state.remapEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("F1–F12 як медіаклавіші")
                    Button(expanded ? "Сховати клавіші" : "Налаштувати клавіші") {
                        withAnimation { expanded.toggle() }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            .toggleStyle(.trailingSwitch).controlSize(.small)
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(0..<12, id: \.self) { i in
                        GridRow {
                            Text("F\(i + 1)").monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .leading)
                            Image(systemName: model.state.fKeys.actions[i].symbol).frame(width: 18)
                            Picker("", selection: $model.state.fKeys.actions[i]) {
                                ForEach(KeyAction.allCases) { Text($0.name).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                }
                .disabled(!model.state.remapEnabled)
                Button("Як на MacBook") { model.state.fKeys = .macBook }
                    .controlSize(.small)
            }
        }
    }
}

/// Apps whose new unread messages (Dock badge) pulse the keyboard in their colour.
/// Several at once take turns, one colour per breath.
struct BadgeAlertControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Сповіщення")
                    Text("Блимає кольором програми, коли щось чекає на тебе")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.badgeAlerts.isEmpty || !model.claudeWaiting.isEmpty {
                    Spacer()
                    Button("Зняти") {
                        model.clearBadgeAlerts()
                        model.clearClaudeAlert()
                    }.controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Text("Claude").help("Коли Claude Code чекає на відповідь або дозвіл")
                Spacer()
                if model.state.claudeAlert && !model.claudeWaiting.isEmpty {
                    Text("\(model.claudeWaiting.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.orange)
                }
                RoundedRectangle(cornerRadius: 4).fill(Color.orange)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5)))
                    .frame(width: 36, height: 18)
                    .help("Колір Claude фіксований")
                Toggle("Claude", isOn: $model.state.claudeAlert).labelsHidden().toggleStyle(.checkbox)
            }
            ForEach($model.state.badgeApps) { $app in
                HStack(spacing: 8) {
                    Text(app.name)
                    Spacer()
                    if let n = model.badgeCounts[app.id], n > 0, app.enabled {
                        Text("\(n)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(model.badgeAlerts[app.id] != nil ? app.color.color : Color.secondary)
                    }
                    RGBWell(color: app.color) { [model, id = app.id] c in
                        if let i = model.state.badgeApps.firstIndex(where: { $0.id == id }) {
                            model.state.badgeApps[i].color = c
                        }
                    }
                    Toggle(app.name, isOn: $app.enabled).labelsHidden().toggleStyle(.checkbox)
                }
            }
        }
    }
}

struct HotkeyOverlayControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { model.state.hotkeyOverlay }, set: { model.enableHotkeyOverlay($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Підсвітка гарячих клавіш")
                    Text("Затисни ⌘, ⌥ або ⌃: світяться клавіші зі скороченнями поточної програми")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.trailingSwitch).controlSize(.small)
            if model.state.hotkeyOverlay && !model.axTrusted {
                HStack {
                    Text("Потрібен дозвіл «Доступність»").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Відкрити") { MenuShortcutReader.openSettings() }.controlSize(.small)
                }
            }
        }
    }
}

struct VisualizerControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Toggle(isOn: $model.state.visualizer) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Візуалізатор музики")
                Text(AppModel.visualizerSupported
                     ? "Еквалайзер на клаві, поки Mac грає звук"
                     : "Потрібна macOS 14.2 або новіша")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.trailingSwitch).controlSize(.small)
        .disabled(!AppModel.visualizerSupported)
        if model.state.visualizer {
            Picker("Стиль", selection: $model.state.visualizerStyle) {
                ForEach(VisualizerStyle.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            .disabled(model.state.visualizerMix)
            Toggle("Mix: усі стилі по черзі", isOn: $model.state.visualizerMix)
                .toggleStyle(.trailingCheckbox)
            if model.state.visualizerMix {
                HStack {
                    Text("Кожні \(Int(model.state.visualizerMixSeconds)) с")
                        .font(.caption).monospacedDigit().frame(width: 70, alignment: .leading)
                    Slider(value: $model.state.visualizerMixSeconds, in: 5...120, step: 5)
                }
            }
        }
    }
}

/// Label on the left, the control pinned to the right edge.
struct TrailingToggleStyle: ToggleStyle {
    var checkbox = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center) {
            configuration.label
            Spacer(minLength: 8)
            if checkbox {
                Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.checkbox)
            } else {
                Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

extension ToggleStyle where Self == TrailingToggleStyle {
    static var trailingSwitch: TrailingToggleStyle { TrailingToggleStyle() }
    static var trailingCheckbox: TrailingToggleStyle { TrailingToggleStyle(checkbox: true) }
}
