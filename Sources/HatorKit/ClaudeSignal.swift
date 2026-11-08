import Foundation

/// Bridge between Claude Code hooks and the app: the `hator claude wait|clear` CLI posts a
/// distributed notification, the running app listens and pulses the keyboard orange.
public enum ClaudeSignal {
    public static let name = Notification.Name("local.hatorrgb.claude")

    public enum State: String, Sendable { case wait, clear }

    /// Called from a hook. Reads the hook's JSON from stdin to get the session id.
    public static func post(_ state: State, hookInput: Data) {
        var session = "default"
        if let obj = try? JSONSerialization.jsonObject(with: hookInput) as? [String: Any],
           let id = obj["session_id"] as? String, !id.isEmpty {
            session = id
        }
        DistributedNotificationCenter.default().postNotificationName(
            name, object: session, userInfo: ["state": state.rawValue], deliverImmediately: true)
    }
}
