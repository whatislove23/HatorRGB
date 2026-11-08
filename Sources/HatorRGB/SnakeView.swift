import SwiftUI
import AppKit
import HatorKit

struct SnakeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var game = SnakeGame()
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Змійка").font(.title2.bold())
                Spacer()
                Text("Рахунок \(game.score)").font(.title3.monospacedDigit())
                Text("Рекорд \(game.best)").foregroundStyle(.secondary).monospacedDigit()
            }

            Text(status).foregroundStyle(.secondary)

            LEDMirror(frame: game.frame, layout: model.state.layout)

            HStack {
                Text("Стрілки — керування · Пробіл — старт / пауза · Esc — пауза")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Заново") { game.reset() }
                Button(game.phase == .running ? "Пауза" : "Старт") {
                    game.phase == .running ? game.pause() : game.start()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            // Pause when the game window loses focus: arrows would go elsewhere.
            if (note.object as? NSWindow)?.title == "Змійка — HATOR" { game.pause() }
        }
    }

    private var status: String {
        if !model.connected { return "Клавіатуру не підключено — граємо лише на екрані." }
        switch game.phase {
        case .ready: return "Дивись на клавіатуру! Натисни стрілку, щоб почати."
        case .running: return "Їж червоні клавіші. Не вкуси себе."
        case .paused: return "Пауза. Стрілка або пробіл — продовжити."
        case .over: return "Гру завершено: \(game.score). Пробіл — ще раз."
        }
    }

    private func begin() {
        model.ledOverride = true
        game.output = { [weak model] in model?.showFrame($0) }
        game.configure(layout: model.state.layout)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.title == "Змійка — HATOR",
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            return game.handle(keyCode: event.keyCode) ? nil : event
        }
    }

    private func end() {
        game.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.ledOverride = false
        model.applyNow()
    }
}

/// On-screen copy of what the keyboard shows.
struct LEDMirror: View {
    let frame: [RGB]
    let layout: KeyLayout
    private let cell: CGFloat = 30, gap: CGFloat = 3

    var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<HatorProtocol.rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<HatorProtocol.columns, id: \.self) { col in
                        let slot = KeyLayout.slot(row: row, column: col)
                        if layout.labels[slot] != nil {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(frame[slot].color)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.08)))
                                .frame(width: cell, height: cell)
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85)))
    }
}
