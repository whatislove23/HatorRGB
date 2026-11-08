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
                    ColorPicker("", selection: color(\.foreground), supportsOpacity: false).labelsHidden()
                    if settings.effect.usesBackground {
                        Text("Фон").foregroundStyle(.secondary)
                        ColorPicker("", selection: color(\.background), supportsOpacity: false).labelsHidden()
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

    private func color(_ kp: WritableKeyPath<EffectSettings, RGB>) -> Binding<Color> {
        Binding(get: { settings[keyPath: kp].color }, set: { settings[keyPath: kp] = RGB($0) })
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
