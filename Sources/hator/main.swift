import Foundation
import HatorKit

let usage = """
usage:
  hator effect <static|breathe|wave|neon|snake|reactive|aurora|ripple>
               [--color RRGGBB] [--bg RRGGBB] [--brightness 0-4] [--speed 0-4]
               [--dir right|left|up|down|outward|inward|clockwise|counterclockwise] [--rainbow]
  hator fill RRGGBB [--brightness 0-4]     all keys one colour (per-key mode)
  hator slot N [RRGGBB]                    light only LED slot N (0-131), for mapping
  hator off
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail(usage) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func color(_ s: String?) -> RGB? {
    guard let s else { return nil }
    guard let c = RGB(hex: s) else { fail("bad colour: \(s)") }
    return c
}
func level(_ name: String) -> UInt8? {
    guard let s = option(name) else { return nil }
    guard let v = UInt8(s), v <= 4 else { fail("\(name) must be 0-4") }
    return v
}

let device = HatorDevice()
guard device.isConnected else { fail("HATOR keyboard (0416:b23c) not found") }

do {
    switch cmd {
    case "effect":
        guard let name = args.first,
              let e = Effect.presets.first(where: { $0.name.lowercased() == name.lowercased() || (name == "static" && $0 == .staticColor) })
        else { fail(usage) }
        var s = EffectSettings()
        s.effect = e
        s.rainbow = args.contains("--rainbow")
        s.foreground = color(option("--color")) ?? s.foreground
        s.background = color(option("--bg")) ?? s.background
        s.brightness = level("--brightness") ?? s.brightness
        s.speed = level("--speed") ?? s.speed
        if let d = option("--dir") {
            guard let dir = Direction.allCases.first(where: { "\($0)".lowercased() == d.lowercased() }) else { fail("bad direction") }
            s.direction = dir
        }
        try device.apply(s)
    case "fill":
        guard let c = color(args.first) else { fail(usage) }
        try device.applyPerKey(Array(repeating: c, count: HatorProtocol.slotCount), brightness: level("--brightness") ?? 4)
    case "slot":
        guard let n = args.first.flatMap(Int.init), (0..<HatorProtocol.slotCount).contains(n) else { fail(usage) }
        var colors = Array(repeating: RGB.black, count: HatorProtocol.slotCount)
        colors[n] = color(args.dropFirst().first) ?? .white
        try device.applyPerKey(colors)
    case "off":
        try device.applyPerKey(Array(repeating: .black, count: HatorProtocol.slotCount), brightness: 0)
    default:
        fail(usage)
    }
} catch {
    fail("error: \(error)")
}
