import SwiftUI
import AppKit
import HatorKit

/// Snake played on the keyboard's own LEDs: every lit key is a pixel, the arrow keys steer
/// (and glow to show the current heading). Gaps in the LED matrix are skipped and the
/// field wraps around at the edges.
@MainActor
final class SnakeGame: ObservableObject {
    enum Phase { case ready, running, paused, over }
    enum Dir: CaseIterable {
        case up, down, left, right
        var delta: (Int, Int) {
            switch self {
            case .up: (-1, 0)
            case .down: (1, 0)
            case .left: (0, -1)
            case .right: (0, 1)
            }
        }
        var opposite: Dir {
            switch self {
            case .up: .down
            case .down: .up
            case .left: .right
            case .right: .left
            }
        }
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var score = 0
    @Published private(set) var best = UserDefaults.standard.integer(forKey: "snake.best")
    @Published private(set) var frame = Array(repeating: RGB.black, count: HatorProtocol.slotCount)

    private var field: [Int] = []
    private var fieldSet: Set<Int> = []
    private var arrows: [Dir: Int] = [:]
    private var snake: [Int] = []          // head first
    private var dir: Dir = .right
    private var queued: [Dir] = []
    private var food = -1
    private var tick = 0
    private var loop: Task<Void, Never>?
    var output: (([RGB]) -> Void)?

    private let rows = HatorProtocol.rows, cols = HatorProtocol.columns

    /// Builds the playfield from the key layout: every slot with an LED except the arrows.
    func configure(layout: KeyLayout) {
        let arrowLabels: [String: Dir] = ["↑": .up, "↓": .down, "←": .left, "→": .right]
        arrows = [:]
        field = []
        for (slot, label) in layout.labels.enumerated() {
            guard let label else { continue }
            if let d = arrowLabels[label] { arrows[d] = slot } else { field.append(slot) }
        }
        fieldSet = Set(field)
        reset()
    }

    func reset() {
        loop?.cancel()
        score = 0
        dir = .right
        queued = []
        // Start in the middle of the letter rows, three segments long.
        let start = fieldSet.contains(KeyLayout.slot(row: 3, column: 6)) ? KeyLayout.slot(row: 3, column: 6) : (field.first ?? 0)
        snake = [start]
        for _ in 0..<2 { if let prev = step(from: snake.last!, .left), !snake.contains(prev) { snake.append(prev) } }
        placeFood()
        phase = .ready
        render()
    }

    // MARK: Input

    /// Returns true if the key was consumed.
    func handle(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 126: turn(.up)
        case 125: turn(.down)
        case 123: turn(.left)
        case 124: turn(.right)
        case 49: // Space
            switch phase {
            case .ready, .paused: start()
            case .running: pause()
            case .over: reset(); start()
            }
        case 53: // Esc
            if phase == .running { pause() }
        default:
            return false
        }
        return true
    }

    private func turn(_ d: Dir) {
        let last = queued.last ?? dir
        guard d != last, d != last.opposite, queued.count < 3 else { return }
        queued.append(d)
        if phase == .ready || phase == .paused { start() }
    }

    func start() {
        guard phase != .running else { return }
        if phase == .over { reset() }
        phase = .running
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.interval)
                guard !Task.isCancelled, self.phase == .running else { return }
                self.advance()
            }
        }
    }

    func pause() {
        guard phase == .running else { return }
        phase = .paused
        loop?.cancel()
        render()
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Speeds up as the snake grows: 260 ms → 90 ms per step.
    private var interval: UInt64 {
        UInt64(max(90, 260 - score * 9)) * 1_000_000
    }

    // MARK: Simulation

    /// Next field cell in direction `d`, skipping LED-less gaps and wrapping at the edges.
    private func step(from slot: Int, _ d: Dir) -> Int? {
        var r = slot / cols, c = slot % cols
        let (dr, dc) = d.delta
        for _ in 0..<max(rows, cols) {
            r = (r + dr + rows) % rows
            c = (c + dc + cols) % cols
            let s = KeyLayout.slot(row: r, column: c)
            if fieldSet.contains(s) { return s }
        }
        return nil
    }

    private func advance() {
        if !queued.isEmpty { dir = queued.removeFirst() }
        guard let head = snake.first, let next = step(from: head, dir) else { return gameOver() }
        let eating = next == food
        let body = eating ? snake : Array(snake.dropLast())
        if body.contains(next) { return gameOver() }
        snake = [next] + body
        if eating {
            score += 1
            if score > best { best = score; UserDefaults.standard.set(best, forKey: "snake.best") }
            placeFood()
        }
        tick += 1
        render()
    }

    private func placeFood() {
        let free = field.filter { !snake.contains($0) }
        food = free.randomElement() ?? -1
    }

    private func gameOver() {
        phase = .over
        loop?.cancel()
        // Flash the snake red a few times.
        loop = Task { [weak self] in
            for i in 0..<6 {
                guard let self, !Task.isCancelled else { return }
                self.render(flash: i % 2 == 0)
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            self?.render()
        }
    }

    // MARK: Rendering

    private func render(flash: Bool = false) {
        var f = Array(repeating: RGB.black, count: HatorProtocol.slotCount)
        let backdrop = RGB(0, 0, 18)
        for s in field { f[s] = backdrop }

        if food >= 0 {
            // Pulse the food between deep and bright red.
            let pulse = UInt8(150 + (tick % 2) * 105)
            f[food] = RGB(pulse, 0, 30)
        }

        let n = max(snake.count, 1)
        for (i, s) in snake.enumerated() {
            if phase == .over {
                f[s] = flash ? RGB(255, 0, 0) : RGB(90, 0, 0)
            } else if i == 0 {
                f[s] = RGB(180, 255, 180)
            } else {
                // Body fades from bright to dim green toward the tail.
                let k = 1.0 - Double(i) / Double(n) * 0.75
                f[s] = RGB(0, UInt8(255 * k), UInt8(60 * k))
            }
        }

        for (d, s) in arrows {
            switch phase {
            case .running: f[s] = d == dir ? RGB(255, 200, 0) : RGB(40, 25, 0)
            case .ready, .paused: f[s] = RGB(255, 200, 0)
            case .over: f[s] = RGB(60, 0, 0)
            }
        }

        frame = f
        output?(f)
    }
}
