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

        Window("Змійка — HATOR", id: "snake") {
            SnakeView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HATOR Gaming Keyboard").font(.headline)
                Spacer()
                Circle().fill(model.connected ? .green : .red).frame(width: 8, height: 8)
                Text(model.connected ? "підключено" : "не знайдено")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("", selection: $model.state.mode) {
                Text("Ефекти").tag(LightMode.effect)
                Text("Поклавішно").tag(LightMode.perKey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.state.mode == .effect {
                EffectControls(settings: $model.state.effect)
            } else {
                PerKeyControls(openEditor: openEditor)
            }

            Button {
                openWindow(id: "snake")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Змійка на клавіатурі", systemImage: "gamecontroller")
                    .frame(maxWidth: .infinity)
            }

            Divider()
            ClaudeAlertControls()
            BadgeAlertControls()
            HotkeyOverlayControls()

            Divider()
            FKeyControls()

            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Divider()
            HStack {
                Toggle("Запускати при вході", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Вийти") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func openEditor() {
        openWindow(id: "editor")
        NSApp.activate(ignoringOtherApps: true)
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
                        Toggle("Веселка", isOn: $settings.rainbow).toggleStyle(.checkbox)
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

            Toggle("Медіаклавіші: білі, ▶︎ зелена / ⏸ червона", isOn: $model.state.mediaKeysGlow)
                .toggleStyle(.checkbox)

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
            .toggleStyle(.switch).controlSize(.small)

            HStack {
                Toggle("F1–F12 як медіаклавіші", isOn: $model.state.remapEnabled)
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button(expanded ? "Сховати" : "Налаштувати") {
                    withAnimation { expanded.toggle() }
                }
                .buttonStyle(.link)
            }
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

struct ClaudeAlertControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Toggle(isOn: $model.state.claudeAlert) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Сигнал від Claude")
                    Text(model.claudeWaiting.isEmpty
                         ? "Блимає помаранчевим, коли Claude чекає на тебе"
                         : "Claude чекає на відповідь (\(model.claudeWaiting.count))")
                        .font(.caption)
                        .foregroundStyle(model.claudeWaiting.isEmpty ? Color.secondary : Color.orange)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            if !model.claudeWaiting.isEmpty {
                Spacer()
                Button("Зняти") { model.clearClaudeAlert() }.controlSize(.small)
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
                    Text("Сповіщення з програм")
                    Text("Блимає кольором програми, коли приходять нові повідомлення")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.badgeAlerts.isEmpty {
                    Spacer()
                    Button("Зняти") { model.clearBadgeAlerts() }.controlSize(.small)
                }
            }
            ForEach($model.state.badgeApps) { $app in
                HStack(spacing: 8) {
                    Toggle(app.name, isOn: $app.enabled).toggleStyle(.checkbox)
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
            .toggleStyle(.switch).controlSize(.small)
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
