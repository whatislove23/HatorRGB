import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import HatorKit

/// Captures what the Mac is playing (all apps) with a Core Audio process tap (macOS 14.2+).
/// macOS asks once for the "System Audio Recording" permission; if denied, the tap delivers silence.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.hatorrgb.audiotap")

    /// Most recent mono samples (ring buffer), read from the main thread.
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 4096)
    private var writeIndex = 0
    private(set) var sampleRate: Double = 48_000

    struct TapError: Error, CustomStringConvertible {
        let step: String, status: OSStatus
        var description: String { "Аудіо (\(step)): \(status)" }
    }

    func start() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        try check("tap", AudioHardwareCreateProcessTap(desc, &tapID))

        var fmtAddr = address(kAudioTapPropertyFormat)
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &fmt) == noErr, fmt.mSampleRate > 0 {
            sampleRate = fmt.mSampleRate
        }

        let outputUID = try defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HatorRGB visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check("aggregate", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
        try check("ioproc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }

    deinit { stop() }

    /// The last `count` samples, oldest first.
    func latest(_ count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let n = min(count, ring.count)
        return (0..<n).map { ring[(writeIndex - n + $0 + ring.count) % ring.count] }
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        let p = data.assumingMemoryBound(to: Float.self)
        lock.lock()
        for i in 0..<frames {
            var s: Float = 0
            for c in 0..<channels { s += p[i * channels + c] }
            ring[writeIndex] = s / Float(channels)
            writeIndex = (writeIndex + 1) % ring.count
        }
        lock.unlock()
    }

    private func defaultOutputUID() throws -> String {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check("output", AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device))
        var uidAddr = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check("output uid", AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &size, &uid))
        return (uid?.takeRetainedValue() as String?) ?? ""
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw TapError(step: step, status: status) }
    }
}

/// Turns audio samples into bar heights (0…1) for a number of log-spaced frequency bands.
final class SpectrumAnalyzer {
    let bands: Int
    private let size = 2048
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var smoothed: [Float]
    private var peak: Float = 1e-3
    /// Unsmoothed kick-range energy of the last analysed block — for beat detection.
    private(set) var lowEnergy: Float = 0

    init(bands: Int) {
        self.bands = bands
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Float(2048))), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 2048, isHalfWindow: false)
        smoothed = Array(repeating: 0, count: bands)
    }

    /// Returns nil when it's (near) silent.
    func heights(_ samples: [Float], sampleRate: Double) -> [Float]? {
        guard samples.count == size else { return nil }
        let rms = vDSP.rootMeanSquare(samples)
        let x = vDSP.multiply(samples, window)
        var re = [Float](repeating: 0, count: size / 2), im = [Float](repeating: 0, count: size / 2)
        var mags = [Float](repeating: 0, count: size / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mags)
            }
        }
        // Log-spaced bands from 40 Hz to 14 kHz.
        let binHz = sampleRate / Double(size)
        let lo = log(40.0), hi = log(14_000.0)
        var raw = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            let f0 = exp(lo + (hi - lo) * Double(b) / Double(bands))
            let f1 = exp(lo + (hi - lo) * Double(b + 1) / Double(bands))
            let i0 = max(1, Int(f0 / binHz)), i1 = min(mags.count - 1, max(i0 + 1, Int(f1 / binHz)))
            raw[b] = mags[i0..<i1].max() ?? 0
            raw[b] *= Float(1 + Double(b) / Double(bands) * 2) // treble is quieter: tilt it up
        }
        // Auto gain: follow the loudest band, decaying slowly.
        peak = max(raw.max() ?? 0, peak * 0.995, 1e-3)
        // Kick-drum range energy (40–150 Hz), unsmoothed.
        let k0 = max(1, Int(40 / binHz)), k1 = max(k0 + 1, Int(150 / binHz))
        lowEnergy = mags[k0..<min(k1, mags.count)].reduce(0) { $0 + $1 * $1 }
        for b in 0..<bands {
            let v = min(1, sqrt(raw[b] / peak))
            smoothed[b] = v > smoothed[b] ? v : smoothed[b] * 0.82 + v * 0.18 // fast up, slow down
        }
        return rms < 0.0005 ? nil : smoothed
    }
}

enum VisualizerStyle: String, Codable, CaseIterable, Identifiable {
    case pulse, bars, beat
    var id: String { rawValue }
    /// Unknown (removed) styles fall back to pulse instead of failing the whole saved state.
    init(from decoder: Decoder) throws {
        self = VisualizerStyle(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pulse
    }
    var name: String {
        switch self {
        case .pulse: "Пульс"
        case .bars: "Стовпчики"
        case .beat: "Біт"
        }
    }
}

/// Changes the whole keyboard to the next colour on every beat (kick), then lets it fade a little
/// until the next one.
final class BeatStyle {
    static let palette: [RGB] = [
        RGB(255, 0, 40), RGB(255, 0, 200), RGB(130, 0, 255), RGB(0, 60, 255),
        RGB(0, 220, 255), RGB(0, 255, 80), RGB(255, 220, 0), RGB(255, 100, 0),
    ]
    let detector = BeatDetector()
    private var lastBeat = Date.distantPast
    private var index = 0

    /// Call every analysis tick (~30/s). Returns the current colour, already faded.
    func color(lowEnergy e: Float) -> RGB {
        if detector.feed(e) {
            lastBeat = Date()
            index = (index + 1) % Self.palette.count
        }
        let t = Float(Date().timeIntervalSince(lastBeat))
        let k = max(0.3, 1 - t * 1.6)
        let col = Self.palette[index]
        return RGB(UInt8(Float(col.r) * k), UInt8(Float(col.g) * k), UInt8(Float(col.b) * k))
    }
}

/// Onset detector on kick-range energy: a beat is a sudden rise in log-energy (spectral flux) that
/// stands out from the rises of the last ~1.5 s. Fed ~30 times per second.
final class BeatDetector {
    private var previousLog: Float?
    private var flux: [Float] = []
    private var ticksSinceBeat = 100
    /// Minimum ticks between beats (~0.2 s at 30/s).
    var refractory = 6

    func feed(_ energy: Float) -> Bool {
        ticksSinceBeat += 1
        let l = log(energy + 1e-7)
        defer { previousLog = l }
        guard let prev = previousLog else { return false }
        let d = max(0, l - prev)
        let mean = flux.isEmpty ? 0 : flux.reduce(0, +) / Float(flux.count)
        let sd = flux.isEmpty ? 0 : sqrt(flux.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(flux.count))
        flux.append(d)
        if flux.count > 45 { flux.removeFirst() }
        guard flux.count > 15, energy > 1e-5, ticksSinceBeat >= refractory,
              d > max(0.35, mean + 1.4 * sd) else { return false }
        ticksSinceBeat = 0
        return true
    }
}

func hsv(_ h: Float, _ s: Float, _ v: Float) -> RGB {
    let i = Int(h * 6) % 6, f = h * 6 - Float(Int(h * 6))
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    let (r, g, b): (Float, Float, Float) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    return RGB(UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
}

/// Whole-keyboard pulse: brightness follows the bass, colour follows where the energy is
/// (bass → red, mids → green, treble → violet). One report per frame, so it's smooth.
final class PulseStyle {
    private var level: Float = 0
    private var hue: Float = 0

    func color(_ heights: [Float]?) -> RGB {
        let h = heights ?? []
        let bass = h.prefix(4).reduce(0, +) / Float(max(1, min(4, h.count)))
        level = bass > level ? bass : level * 0.88 + bass * 0.12
        let total = h.reduce(0, +)
        if total > 0.01 {
            let centroid = zip(h.indices, h).reduce(Float(0)) { $0 + Float($1.0) * $1.1 } / total / Float(h.count)
            hue = hue * 0.93 + min(0.8, centroid * 1.4) * 0.07
        }
        let k = max(0.06, pow(level, 1.5))
        let c = hsv(hue, 1, k)
        return c
    }

}

enum VisualizerFrame {
    /// Columns 0…17 of the 6 × 22 matrix (main block + nav keys); row 5 is the bottom.
    static let columns = 18

    /// Equaliser bars: green at the bottom, yellow in the middle, red on top. Whole cells only (no
    /// half-bright keys): the firmware updates per-key colours slowly, so fewer changes look steadier.
    static func render(_ heights: [Float], layout: KeyLayout) -> [RGB] {
        var frame = Array(repeating: RGB.black, count: HatorProtocol.slotCount)
        let rows = HatorProtocol.rows
        let rowColors = [RGB(255, 0, 0), RGB(255, 90, 0), RGB(255, 200, 0), RGB(160, 255, 0), RGB(0, 255, 40), RGB(0, 255, 40)]
        for col in 0..<min(columns, heights.count) {
            let lit = Int((heights[col] * Float(rows)).rounded())
            for k in 0..<min(lit, rows) { // k = 0 is the bottom row
                let row = rows - 1 - k
                let slot = KeyLayout.slot(row: row, column: col)
                guard layout.labels[slot] != nil else { continue }
                frame[slot] = rowColors[row]
            }
        }
        return frame
    }
}
