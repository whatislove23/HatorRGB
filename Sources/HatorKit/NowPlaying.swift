import Foundation
import CoreAudio

/// Whether music (or any media) is playing right now. No permissions needed.
/// Uses the system Now Playing state (MediaRemote, the same thing Control Center shows); if that's
/// unavailable, falls back to "the default output device is producing audio".
public enum NowPlaying {
    public enum State: Sendable { case none, paused, playing }

    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias PIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void

    private static let mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    private static let isPlayingFn: IsPlayingFn? = dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
        .map { unsafeBitCast($0, to: IsPlayingFn.self) }
    private static let pidFn: PIDFn? = dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingApplicationPID")
        .map { unsafeBitCast($0, to: PIDFn.self) }

    /// none = no media app; paused = a player has a session but is paused. Calls back on the main queue.
    public static func check(_ done: @escaping (State) -> Void) {
        guard let isPlayingFn, let pidFn else {
            done(outputRunning() ? .playing : .none)
            return
        }
        isPlayingFn(DispatchQueue.main) { playing in
            if playing { done(.playing); return }
            pidFn(DispatchQueue.main) { pid in done(pid > 0 ? .paused : .none) }
        }
    }

    public static func outputRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
        else { return false }
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running = UInt32(0)
        size = 4
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
