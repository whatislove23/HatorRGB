import AppKit
import ApplicationServices
import CoreAudio
import os

let callLog = Logger(subsystem: "local.hatorrgb", category: "calls")

/// Whether you're on a call, and whether your microphone is muted in the call app.
///
/// The mute button lives inside each call app (apps keep recording while muted), so its state is read
/// from the app's UI via Accessibility (same permission as the hotkey overlay):
/// - Zoom: the "Meeting" menu has "Mute Audio" / "Unmute Audio" while in a meeting.
/// - Google Meet (any browser), Slack huddles, Telegram: the call window has a microphone button whose
///   label says what pressing it would do ("Turn off microphone" = live, "Unmute" = muted).
enum CallMonitor {
    enum State: Equatable, Sendable { case none, live, muted }

    static let zoom: Set<String> = ["us.zoom.xos"]
    static let apps: Set<String> = [
        "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram", "org.telegram.desktop",
    ]
    static let browsers: Set<String> = [
        "com.google.Chrome", "company.thebrowser.Browser", "com.apple.Safari", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Some app is capturing a microphone right now (no permission needed). On macOS 14.2+ asks
    /// Core Audio which processes are recording; before that, checks every input device.
    static func micInUse() -> Bool {
        if #available(macOS 14.2, *) {
            // Skip ourselves: the visualizer's system-audio tap also counts as input.
            for obj in objects(kAudioHardwarePropertyProcessObjectList)
            where uint(obj, kAudioProcessPropertyIsRunningInput) != 0
                && Int32(bitPattern: uint(obj, kAudioProcessPropertyPID)) != getpid() { return true }
            return false
        }
        for dev in objects(kAudioHardwarePropertyDevices) where hasInput(dev) {
            if uint(dev, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 { return true }
        }
        return false
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v = UInt32(0), size = UInt32(4)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : 0
    }

    private static func hasInput(_ dev: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// Which call app owns an audio process (helpers like "com.google.Chrome.helper" count as Chrome).
    private static func callApp(for bundleID: String) -> String? {
        if bundleID.hasPrefix("com.apple.WebKit") { return "com.apple.Safari" }
        return (zoom.union(apps).union(browsers)).first { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    /// A call app (or its helper process) is recording right now.
    private static func callAppRecording() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        return objects(kAudioHardwarePropertyProcessObjectList).contains { obj in
            uint(obj, kAudioProcessPropertyIsRunningInput) != 0
                && string(obj, kAudioProcessPropertyBundleID).flatMap(callApp(for:)) != nil
        }
    }

    private static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }

    /// Looks through the running call apps. Slow-ish (walks UI trees): call off the main thread.
    static func scan() -> State {
        var found: [State] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier
            var st: State?
            if zoom.contains(id) {
                st = zoomState(pid: pid)
            } else if apps.contains(id) {
                st = windowsState(pid: pid, titleFilter: nil)
            } else if browsers.contains(id) {
                st = windowsState(pid: pid, titleFilter: "meet")
            }
            if let st { found.append(st) }
        }
        // A mute button read from the app's UI is the most direct answer; a live mic wins over muted.
        if found.contains(.live) { return .live }
        if found.contains(.muted) { return .muted }
        // No mute button visible (e.g. the call window is on another desktop): a call app recording
        // still means you can be heard.
        return callAppRecording() ? .live : .none
    }

    // MARK: Zoom

    private static func zoomState(pid: pid_t) -> State {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar: AXUIElement = attr(app, kAXMenuBarAttribute) else { return .none }
        for menu in children(bar) {
            for list in children(menu) {
                for item in children(list) {
                    let title = (attr(item, kAXTitleAttribute) as String?)?.lowercased() ?? ""
                    if title.hasPrefix("unmute audio") { return .muted }
                    if title.hasPrefix("mute audio") { return .live }
                }
            }
        }
        // Fall back to the meeting window's own buttons.
        return windowsState(pid: pid, titleFilter: nil)
    }

    // MARK: Generic window search

    private static var webAXEnabled: Set<pid_t> = []

    private static func windowsState(pid: pid_t, titleFilter: String?) -> State {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        // Chromium / Electron only expose their UI fully to Accessibility once asked to.
        if !webAXEnabled.contains(pid) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            webAXEnabled.insert(pid)
        }
        var windows: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        if windows.isEmpty, let main: AXUIElement = attr(app, kAXMainWindowAttribute) { windows = [main] }
        let targets = windows.filter { w in
            guard let f = titleFilter else { return true }
            return ((attr(w, kAXTitleAttribute) as String?) ?? "").lowercased().contains(f)
        }
        guard !targets.isEmpty else { return .none }
        for w in targets {
            if let s = search(w) { return s }
        }
        return .none
    }

    /// Breadth-first search for a microphone toggle; capped so a huge page can't stall us.
    private static func search(_ root: AXUIElement) -> State? {
        var queue = [root], visited = 0
        while !queue.isEmpty, visited < 6000 {
            let el = queue.removeFirst()
            visited += 1
            let role: String = attr(el, kAXRoleAttribute) ?? ""
            if role == kAXButtonRole || role == kAXCheckBoxRole || role == "AXToggle" {
                let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .compactMap { attr(el, $0) as String? }.joined(separator: " ")
                if let s = classify(label) {
                    callLog.debug("mic button: \(label, privacy: .public) → \(String(describing: s), privacy: .public)")
                    return s
                }
            }
            queue += children(el)
        }
        return nil
    }

    /// The label says what pressing the button would do.
    static func classify(_ raw: String) -> State? {
        let s = raw.lowercased()
        guard !s.isEmpty else { return nil }
        let micWords = ["microphone", "mic", "audio", "мікрофон", "микрофон"]
        let exact = s.trimmingCharacters(in: .whitespaces)
        let aboutMic = micWords.contains { s.contains($0) } || exact == "mute" || exact == "unmute"
        guard aboutMic else { return nil }
        // Skip speaker / video / settings buttons.
        if ["camera", "video", "speaker", "settings", "options", "камер", "динамік"].contains(where: { s.contains($0) }) {
            return nil
        }
        let turnsOn = ["unmute", "turn on", "увімкнути", "включить", "увімкн", "включ"]
        let turnsOff = ["mute", "turn off", "вимкнути", "выключить", "вимкн", "выключ"]
        if turnsOn.contains(where: { s.contains($0) }) { return .muted }
        if turnsOff.contains(where: { s.contains($0) }) { return .live }
        return nil
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        attr(el, kAXChildrenAttribute) ?? []
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }
}
