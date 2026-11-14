import Foundation

/// Reads an app's Dock badge (the red unread counter) through `lsappinfo`. No permissions needed.
public enum BadgeReader {
    /// Badge of the running app with this pid: nil = no badge; a non-numeric badge (e.g. "•") counts as 1.
    public static func count(pid: pid_t) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        p.arguments = ["info", "-only", "StatusLabel", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses `"StatusLabel"={ "label"="3" }`.
    static func parse(_ s: String) -> Int? {
        guard let r = s.range(of: #""label"="[^"]*""#, options: .regularExpression) else { return nil }
        let label = s[r].dropFirst(9).dropLast() // strip `"label"="` and the closing quote
        guard !label.isEmpty else { return nil }
        return Int(label.filter(\.isNumber)) ?? 1
    }
}
