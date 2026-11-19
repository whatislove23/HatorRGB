import Foundation
import HatorKit

enum VisualizerStyle: String, Codable, CaseIterable, Identifiable {
    case bars, hbars, hits, stereo, stars, sine
    var id: String { rawValue }
    /// Unknown (removed) styles fall back to bars instead of failing the whole saved state.
    init(from decoder: Decoder) throws {
        self = VisualizerStyle(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .bars
    }
    var name: String {
        switch self {
        case .bars: "Стовпчики"
        case .hbars: "Смуги"
        case .hits: "Удари"
        case .stereo: "Стерео"
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
        case .bars: BarsVisual(horizontal: false)
        case .hbars: BarsVisual(horizontal: true)
        case .hits: HitsVisual()
        case .stereo: StereoVisual()
        case .stars: StarsVisual()
        case .sine: SineVisual()
        }
    }
}

/// A visualizer on the 6 × 18 key grid. `update` runs every analysis tick (~30/s, so nothing is
/// missed); `frame` runs only when a frame is actually sent (~8–10/s).
extension GridVisual {
    func updateStereo(left: Float, right: Float) {}
}

protocol GridVisual: AnyObject {
    func update(_ heights: [Float]?, rms: Float, dt: Double)
    /// Loudness (RMS) of the left and right channels, before `update`.
    func updateStereo(left: Float, right: Float)
    func frame(layout: KeyLayout) -> [RGB]
}

/// Helpers shared by the styles.
enum LedGrid {
    static let rows = HatorProtocol.rows
    static let cols = VisualizerFrame.columns
    static func blank() -> [RGB] { Array(repeating: .black, count: HatorProtocol.slotCount) }
    static func set(_ frame: inout [RGB], _ row: Int, _ col: Int, _ c: RGB, _ layout: KeyLayout) {
        for slot in slots(row, col, layout) { frame[slot] = c }
    }

    /// The keys at a *physical* grid cell: row = keyboard row, col = 1-key-wide strip across the board
    /// (by where the key's centre is). The LED matrix columns are skewed (column 2 is 2 / W / A / Z / Alt),
    /// so going by the matrix made bars run diagonally with holes.
    static func slots(_ row: Int, _ col: Int, _ layout: KeyLayout) -> [Int] {
        guard (0..<rows).contains(row), (0..<cols).contains(col) else { return [] }
        if cachedLayout != layout.labels {
            cachedLayout = layout.labels
            cells = buildCells(layout)
        }
        return cells[row * cols + col]
    }
    private nonisolated(unsafe) static var cachedLayout: [String?] = []
    private nonisolated(unsafe) static var cells: [[Int]] = []

    /// Key centres (in key widths from the left edge) of a TKL ANSI board, per row, in left-to-right order.
    private static let centres: [[(String, Double)]] = [
        [("Esc", 0.5), ("F1", 2.5), ("F2", 3.5), ("F3", 4.5), ("F4", 5.5), ("F5", 7), ("F6", 8), ("F7", 9),
         ("F8", 10), ("F9", 11.5), ("F10", 12.5), ("F11", 13.5), ("F12", 14.5),
         ("PrtSc", 15.75), ("ScrLk", 16.75), ("Pause", 17.75)],
        [("`", 0.5), ("1", 1.5), ("2", 2.5), ("3", 3.5), ("4", 4.5), ("5", 5.5), ("6", 6.5), ("7", 7.5),
         ("8", 8.5), ("9", 9.5), ("0", 10.5), ("-", 11.5), ("=", 12.5), ("⌫", 14),
         ("Ins", 15.75), ("Home", 16.75), ("PgUp", 17.75)],
        [("Tab", 0.75), ("Q", 2), ("W", 3), ("E", 4), ("R", 5), ("T", 6), ("Y", 7), ("U", 8), ("I", 9),
         ("O", 10), ("P", 11), ("[", 12), ("]", 13), ("\\", 14.25), ("Del", 15.75), ("End", 16.75), ("PgDn", 17.75)],
        [("Caps", 0.875), ("A", 2.25), ("S", 3.25), ("D", 4.25), ("F", 5.25), ("G", 6.25), ("H", 7.25),
         ("J", 8.25), ("K", 9.25), ("L", 10.25), (";", 11.25), ("'", 12.25), ("Enter", 13.875)],
        [("⇧", 1.125), ("Z", 2.75), ("X", 3.75), ("C", 4.75), ("V", 5.75), ("B", 6.75), ("N", 7.75),
         ("M", 8.75), (",", 9.75), (".", 10.75), ("/", 11.75), ("⇧", 13.625), ("↑", 16.75)],
        [("Ctrl", 0.625), ("Win", 1.875), ("Alt", 3.125), ("Space", 6.875), ("Alt", 10.625), ("Fn", 11.875),
         ("Menu", 13.125), ("Ctrl", 14.375), ("←", 15.75), ("↓", 16.75), ("→", 17.75)],
    ]

    private static let widths: [String: Double] = [
        "Tab": 1.5, "Caps": 1.75, "Enter": 2.25, "⌫": 2, "\\": 1.5, "Space": 6.25,
        "Ctrl": 1.25, "Win": 1.25, "Alt": 1.25, "Fn": 1.25, "Menu": 1.25,
    ]

    private static func buildCells(_ layout: KeyLayout) -> [[Int]] {
        var out = [[Int]](repeating: [], count: rows * cols)
        for r in 0..<rows {
            var used = [String: Int]() // nth occurrence of a label in this row (two ⇧, Alt, Ctrl)
            // Main block and nav cluster only (matrix columns 0…17); the numpad isn't part of the grid.
            for m in 0..<cols {
                let slot = KeyLayout.slot(row: r, column: m)
                guard let label = layout.labels[slot] else { continue }
                let n = used[label, default: 0]
                used[label] = n + 1
                let x = centres[r].filter { $0.0 == label }.dropFirst(n).first?.1 ?? Double(m) + 0.5
                // Wide keys (Shift, Space, Enter…) belong to every strip they cover at least half of,
                // so the bars have no holes under them.
                let w = label == "⇧" ? (n == 0 ? 2.25 : 2.75) : widths[label] ?? 1
                let lo = x - w / 2, hi = x + w / 2
                var covered = (0..<cols).filter { c in min(hi, Double(c + 1)) - max(lo, Double(c)) >= 0.5 }
                if covered.isEmpty { covered = [min(cols - 1, Int(x))] }
                for c in covered { out[r * cols + c].append(slot) }
            }
        }
        return out
    }
    static func scale(_ c: RGB, _ k: Float) -> RGB {
        let k = max(0, min(1, k))
        return RGB(UInt8(Float(c.r) * k), UInt8(Float(c.g) * k), UInt8(Float(c.b) * k))
    }
    static func band(_ h: [Float], _ i: Int) -> Float { h.indices.contains(i) ? h[i] : 0 }
}

// MARK: Bars

/// Equaliser bars: green at the bottom, yellow in the middle, red on top; whole cells only.
/// A bar shows what *changes* in its frequency band, not the raw level (most bands are busy all the
/// time, which kept the bottom rows always lit):
/// - each column tracks its own floor and ceiling over the last few seconds and is stretched between
///   them, so a constant hum reads as 0 and the bar moves over its whole height;
/// - a sudden rise in a band (a hit, a new note) kicks the bar up on top of that, then it settles.
final class BarsVisual: GridVisual {
    /// Horizontal: 6 bars, one per keyboard row (bass at the bottom, treble on top), growing left to
    /// right across 18 keys, green → yellow → red.
    private let horizontal: Bool
    /// Number of bars and how many keys long each can get.
    private let count: Int, length: Int
    private var level: [Float], floor: [Float], ceil: [Float], prev: [Float], hit: [Float]
    /// What's shown: rises quickly, falls at a steady speed; whole keys with a little hysteresis.
    private var shown: [Float]
    private var lit: [Int]
    private static let rowColors = [RGB(255, 0, 0), RGB(255, 90, 0), RGB(255, 200, 0),
                                    RGB(160, 255, 0), RGB(0, 255, 40), RGB(0, 255, 40)]

    init(horizontal: Bool) {
        self.horizontal = horizontal
        count = horizontal ? LedGrid.rows : LedGrid.cols
        length = horizontal ? LedGrid.cols : LedGrid.rows
        level = Array(repeating: 0, count: count)
        floor = level; prev = level; hit = level; shown = level
        ceil = Array(repeating: 0.3, count: count)
        lit = Array(repeating: 0, count: count)
    }

    /// Colour of the k-th key from a bar's start.
    private func color(_ k: Int) -> RGB {
        if !horizontal { return Self.rowColors[LedGrid.rows - 1 - k] }
        // Along the bar: green → yellow by 35%, red from 70% on.
        let t = Float(k) / Float(length - 1)
        if t < 0.35 { return RGB(UInt8(min(255, t / 0.35 * 255)), 255, 40) }
        if t < 0.7 { return RGB(255, UInt8(max(0, (1 - (t - 0.35) / 0.35) * 255)), 0) }
        return RGB(255, 0, 0)
    }

    func update(_ h: [Float]?, rms: Float, dt: Double) {
        guard let h else {
            level = level.map { _ in 0 }; hit = hit.map { _ in 0 }; shown = shown.map { _ in 0 }; lit = lit.map { _ in 0 }
            return
        }
        let per = max(1, h.count / count)
        for c in 0..<count {
            // Horizontal: each row takes three neighbouring bands (their loudest).
            let v = per > 1 ? (0..<per).map { LedGrid.band(h, c * per + $0) }.max() ?? 0 : LedGrid.band(h, c)
            // Floor: drops at once, creeps up over ~3 s. Ceiling: jumps up at once, eases down over ~3 s.
            floor[c] = v < floor[c] ? v : floor[c] + (v - floor[c]) * 0.008
            ceil[c] = v > ceil[c] ? v : ceil[c] + (v - ceil[c]) * 0.008
            let span = max(0.15, ceil[c] - floor[c])
            let stretched = max(0, min(1, (v - floor[c]) / span))
            // A sudden rise kicks the bar up; the kick fades in ~0.3 s.
            let rise = max(0, v - prev[c])
            prev[c] = v
            hit[c] = max(hit[c] * 0.88, min(1, rise * 3))
            // ×1.15 so the loudest moments clearly reach the red end.
            level[c] = min(1, max(stretched * 1.15, hit[c]))
            // Quick (not instant) rise, steady fall: a full bar drops in about half a second.
            shown[c] = level[c] > shown[c] ? shown[c] + (level[c] - shown[c]) * 0.55
                                           : max(level[c], shown[c] - Float(dt) * 2)
            let x = shown[c] * Float(length)
            if x >= Float(lit[c]) + 0.6 { lit[c] = min(length, Int(x + 0.4)) }
            else if x <= Float(lit[c]) - 0.7 { lit[c] = max(0, Int(x + 0.5)) }
        }
    }

    func frame(layout: KeyLayout) -> [RGB] {
        var f = LedGrid.blank()
        for c in 0..<count {
            for k in 0..<lit[c] {
                if horizontal {
                    LedGrid.set(&f, LedGrid.rows - 1 - c, k, color(k), layout)
                } else {
                    LedGrid.set(&f, LedGrid.rows - 1 - k, c, color(k), layout)
                }
            }
        }
        return f
    }
}

// MARK: Hits

/// Each column fires when something new starts in its band — a drum hit, a note, a syllable — and
/// falls back within ~⅓ s. Steady sounds don't hold it up, so the keyboard follows the rhythm.
/// The harder the hit, the higher the bar; colours by row like the bars (green at the bottom, red on top).
final class HitsVisual: GridVisual {
    private var prev = [Float](repeating: 0, count: LedGrid.cols)
    private var avgFlux = [Float](repeating: 0.02, count: LedGrid.cols)
    private var level = [Float](repeating: 0, count: LedGrid.cols)
    private var since = [Double](repeating: 1, count: LedGrid.cols)
    private static let rowColors = [RGB(255, 0, 0), RGB(255, 90, 0), RGB(255, 200, 0),
                                    RGB(160, 255, 0), RGB(0, 255, 40), RGB(0, 255, 40)]

    func update(_ h: [Float]?, rms: Float, dt: Double) {
        guard let h else { level = level.map { _ in 0 }; return }
        for c in 0..<LedGrid.cols {
            let v = LedGrid.band(h, c)
            let flux = max(0, v - prev[c])
            prev[c] = v
            since[c] += dt
            // An onset: a rise well above this band's usual rises.
            if flux > avgFlux[c] * 2.5 + 0.03, since[c] > 0.12 {
                level[c] = max(level[c], min(1, 0.35 + flux * 4))
                since[c] = 0
            }
            avgFlux[c] += (flux - avgFlux[c]) * 0.05
            level[c] = max(0, level[c] - Float(dt) * 3)
        }
    }

    func frame(layout: KeyLayout) -> [RGB] {
        var f = LedGrid.blank()
        for c in 0..<LedGrid.cols {
            let lit = min(LedGrid.rows, Int((level[c] * Float(LedGrid.rows)).rounded()))
            for k in 0..<lit {
                let row = LedGrid.rows - 1 - k
                LedGrid.set(&f, row, c, Self.rowColors[row], layout)
            }
        }
        return f
    }
}

// MARK: Stereo

/// Stereo level meter from the middle of the keyboard (as in KeyboardAudioVisualizer's "Level"):
/// the left channel grows from the centre to the left edge, the right channel to the right edge, on
/// all rows; green near the centre, yellow, red at the edges. Levels in dB around the track's average
/// loudness (last ~3 s): average sits at the middle of each half, +9 dB reaches the edge. So player
/// volume doesn't matter and only the louder moments hit red. Quick rise, steady fall like a real VU.
final class StereoVisual: GridVisual {
    private var raw: (Float, Float) = (0, 0)
    private var avg: Float = -30
    private var shown: [Float] = [0, 0]
    private var lit: [Int] = [0, 0]
    private static let half = LedGrid.cols / 2, range: Float = 18

    func updateStereo(left: Float, right: Float) { raw = (left, right) }

    func update(_ h: [Float]?, rms: Float, dt: Double) {
        guard h != nil else { shown = [0, 0]; lit = [0, 0]; return }
        let db = [raw.0, raw.1].map { 20 * log10(max($0, 1e-6)) }
        let mean = (db[0] + db[1]) / 2
        avg += (mean - avg) * Float(min(1, dt / 3))
        for i in 0..<2 {
            let v = max(0, min(1, (db[i] - (avg - Self.range / 2)) / Self.range))
            shown[i] = v > shown[i] ? shown[i] + (v - shown[i]) * 0.6 : max(v, shown[i] - Float(dt) * 1.5)
            let x = shown[i] * Float(Self.half)
            if x >= Float(lit[i]) + 0.6 { lit[i] = min(Self.half, Int(x + 0.4)) }
            else if x <= Float(lit[i]) - 0.7 { lit[i] = max(0, Int(x + 0.5)) }
        }
    }

    /// Colour k keys out from the centre: green → yellow → red.
    private func color(_ k: Int) -> RGB {
        let t = Float(k) / Float(Self.half - 1)
        if t < 0.35 { return RGB(UInt8(min(255, t / 0.35 * 255)), 255, 40) }
        if t < 0.7 { return RGB(255, UInt8(max(0, (1 - (t - 0.35) / 0.35) * 255)), 0) }
        return RGB(255, 0, 0)
    }

    func frame(layout: KeyLayout) -> [RGB] {
        var f = LedGrid.blank()
        for k in 0..<Self.half {
            for r in 0..<LedGrid.rows {
                if k < lit[0] { LedGrid.set(&f, r, Self.half - 1 - k, color(k), layout) }
                if k < lit[1] { LedGrid.set(&f, r, Self.half + k, color(k), layout) }
            }
        }
        return f
    }
}

// MARK: Sine

/// A rainbow sine line that changes shape with the music:
/// - height: the bass, stretched between its recent quietest and loudest (so it really goes from a flat
///   line to the full keyboard height);
/// - width: where the sound sits — bass-heavy music makes long, wide waves, bright / busy music short,
///   narrow ones (½ to 3 waves across the keyboard, changing smoothly);
/// - speed: faster with busy highs.
final class SineVisual: GridVisual {
    private var phase = 0.0
    private var amp: Float = 0
    private var waves: Float = 1.5
    private var bassFloor: Float = 0, bassCeil: Float = 0.3
    func update(_ h: [Float]?, rms: Float, dt: Double) {
        let h = h ?? []
        let bass = h.prefix(4).max() ?? 0
        let treble = h.suffix(6).max() ?? 0
        bassFloor = bass < bassFloor ? bass : bassFloor + (bass - bassFloor) * 0.01
        bassCeil = bass > bassCeil ? bass : bassCeil + (bass - bassCeil) * 0.01
        let stretched = max(0, min(1, (bass - bassFloor) / max(0.15, bassCeil - bassFloor)))
        let target = pow(stretched, 1.5)
        amp += (target - amp) * (target > amp ? 0.6 : 0.12)
        // Spectral centroid 0…1 (low → high) sets how many waves fit across.
        let total = h.reduce(0, +)
        if total > 0.01 {
            let centroid = zip(h.indices, h).reduce(Float(0)) { $0 + Float($1.0) * $1.1 } / total / Float(max(1, h.count - 1))
            let target = 0.5 + max(0, min(1, (centroid - 0.25) / 0.4)) * 2.5
            waves += (target - waves) * 0.04
        }
        phase += dt * (1.5 + Double(treble) * 7)
    }

    func frame(layout: KeyLayout) -> [RGB] {
        var f = LedGrid.blank()
        let mid = Double(LedGrid.rows - 1) / 2
        let swing = (mid + 0.4) * Double(max(0.05, min(1, amp)))
        func row(_ col: Int) -> Int {
            let y = mid - swing * sin(Double(col) / Double(LedGrid.cols) * Double(waves) * 2 * .pi - phase)
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
            guard let slot = LedGrid.slots(row, min(col, LedGrid.cols - 1), layout).randomElement(), !stars.contains(where: { $0.slot == slot }) else { continue }
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
