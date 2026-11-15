import Foundation
import HatorKit

enum VisualizerStyle: String, Codable, CaseIterable, Identifiable {
    case bars, stars, sine
    var id: String { rawValue }
    /// Unknown (removed) styles fall back to bars instead of failing the whole saved state.
    init(from decoder: Decoder) throws {
        self = VisualizerStyle(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .bars
    }
    var name: String {
        switch self {
        case .bars: "Стовпчики"
        case .stars: "Зірки"
        case .sine: "Синусоїда"
        }
    }
    /// Styles that redraw most keys every frame get a slightly lower frame rate (keeps typing smooth).
    var frameInterval: TimeInterval {
        self == .sine ? 0.125 : 0.1
    }

    func makeVisual() -> GridVisual {
        switch self {
        case .bars: BarsVisual()
        case .stars: StarsVisual()
        case .sine: SineVisual()
        }
    }
}

/// A visualizer on the 6 × 18 key grid. `update` runs every analysis tick (~30/s, so nothing is
/// missed); `frame` runs only when a frame is actually sent (~8–10/s).
protocol GridVisual: AnyObject {
    func update(_ heights: [Float]?, rms: Float, dt: Double)
    func frame(layout: KeyLayout) -> [RGB]
}

/// Helpers shared by the styles.
enum LedGrid {
    static let rows = HatorProtocol.rows
    static let cols = VisualizerFrame.columns
    static func blank() -> [RGB] { Array(repeating: .black, count: HatorProtocol.slotCount) }
    static func set(_ frame: inout [RGB], _ row: Int, _ col: Int, _ c: RGB, _ layout: KeyLayout) {
        guard (0..<rows).contains(row), (0..<cols).contains(col) else { return }
        let slot = KeyLayout.slot(row: row, column: col)
        if layout.labels[slot] != nil { frame[slot] = c }
    }
    static func scale(_ c: RGB, _ k: Float) -> RGB {
        let k = max(0, min(1, k))
        return RGB(UInt8(Float(c.r) * k), UInt8(Float(c.g) * k), UInt8(Float(c.b) * k))
    }
    static func band(_ h: [Float], _ i: Int) -> Float { h.indices.contains(i) ? h[i] : 0 }
}

// MARK: Bars

/// Equaliser bars: green at the bottom, yellow in the middle, red on top; whole cells only.
final class BarsVisual: GridVisual {
    private var heights: [Float] = []
    private static let rowColors = [RGB(255, 0, 0), RGB(255, 90, 0), RGB(255, 200, 0),
                                    RGB(160, 255, 0), RGB(0, 255, 40), RGB(0, 255, 40)]
    func update(_ h: [Float]?, rms: Float, dt: Double) {
        heights = h ?? []
    }

    func frame(layout: KeyLayout) -> [RGB] {
        var f = LedGrid.blank()
        for c in 0..<LedGrid.cols {
            let lit = min(LedGrid.rows, Int((LedGrid.band(heights, c) * Float(LedGrid.rows)).rounded()))
            for k in 0..<lit { LedGrid.set(&f, LedGrid.rows - 1 - k, c, Self.rowColors[LedGrid.rows - 1 - k], layout) }
        }
        return f
    }
}

// MARK: Sine

/// A rainbow sine line: jumps up on the bass, runs faster with busy highs.
final class SineVisual: GridVisual {
    private var phase = 0.0
    private var amp: Float = 0
    func update(_ h: [Float]?, rms: Float, dt: Double) {
        let h = h ?? []
        let bass = h.prefix(4).max() ?? 0
        let treble = h.suffix(6).max() ?? 0
        let target = pow(bass, 2.2)
        amp += (target - amp) * (target > amp ? 0.6 : 0.1)
        phase += dt * (1.5 + Double(treble) * 7)
    }

    func frame(layout: KeyLayout) -> [RGB] {
        var f = LedGrid.blank()
        let mid = Double(LedGrid.rows - 1) / 2
        let swing = mid * Double(max(0.08, min(1, amp)))
        func row(_ col: Int) -> Int {
            let y = mid - swing * sin(Double(col) / Double(LedGrid.cols) * 3 * .pi - phase)
            return max(0, min(LedGrid.rows - 1, Int(y.rounded())))
        }
        var prev = row(0)
        for col in 0..<LedGrid.cols {
            let r = row(col)
            let color = hsv(Float(col) / Float(LedGrid.cols) * 0.8, 1, 1)
            // Fill vertical gaps between neighbours so the line stays connected.
            let lo = col == 0 ? r : min(r, prev + (r > prev ? 1 : 0))
            let hi = col == 0 ? r : max(r, prev - (r < prev ? 1 : 0))
            for y in lo...hi { LedGrid.set(&f, y, col, color, layout) }
            prev = r
        }
        return f
    }
}

// MARK: Stars

/// Keys sparkle with the music: the louder it is, the more stars. A star's column follows its
/// frequency (bass on the left, treble on the right) and so does its colour; a kick adds a burst.
/// Stars are full, then dim, then off — few brightness steps keep the LED traffic low.
final class StarsVisual: GridVisual {
    private struct Star { var slot: Int; var color: RGB; var age: Double }
    private var stars: [Star] = []
    private var avgBass: Float = 0
    private var sinceKick = 1.0
    private var layout: KeyLayout?
    private static let life = 0.5

    func update(_ h: [Float]?, rms: Float, dt: Double) {
        for i in stars.indices { stars[i].age += dt }
        stars.removeAll { $0.age > Self.life }
        guard let h, let layout else { return }
        let level = h.reduce(0, +) / Float(max(1, h.count))
        let bass = h.prefix(3).max() ?? 0
        sinceKick += dt
        var spawn = Int(Float.random(in: 0..<1) + level * level * 3)
        if bass > 0.45, bass > avgBass * 1.3 + 0.05, sinceKick > 0.2 { sinceKick = 0; spawn += 5 }
        avgBass = avgBass * 0.9 + bass * 0.1
        let weights = h.map { $0 * $0 }
        let total = weights.reduce(0, +)
        guard total > 0 else { return }
        for _ in 0..<min(spawn, 30 - stars.count) {
            // Pick a band in proportion to its energy; that's the column.
            var x = Float.random(in: 0..<total), col = 0
            while col < weights.count - 1, x >= weights[col] { x -= weights[col]; col += 1 }
            let row = Int.random(in: 0..<LedGrid.rows)
            let slot = KeyLayout.slot(row: row, column: min(col, LedGrid.cols - 1))
            guard layout.labels[slot] != nil, !stars.contains(where: { $0.slot == slot }) else { continue }
            stars.append(Star(slot: slot, color: hsv(Float(col) / Float(LedGrid.cols) * 0.8, 1, 1), age: 0))
        }
    }

    func frame(layout: KeyLayout) -> [RGB] {
        self.layout = layout
        var f = LedGrid.blank()
        for s in stars { f[s.slot] = s.age < Self.life * 0.45 ? s.color : LedGrid.scale(s.color, 0.25) }
        return f
    }
}
