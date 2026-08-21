import AppKit
import CoreAudio
import Darwin

/// Best-effort bridge to the system Now Playing session. A dedicated Pause /
/// Play command is used when MediaRemote is available, so an idle player can
/// never be accidentally toggled on. The media-key path remains as a fallback
/// for macOS versions where that dynamically looked-up command is unavailable.
enum MediaPlaybackController {
    // NX_KEYTYPE_PLAY from IOKit/hidsystem/ev_keymap.h. Keeping the numeric
    // value local avoids importing the broader IOKit surface just for one key.
    private static let playPauseKeyCode = 16
    private static let playCommand = 0
    private static let pauseCommand = 1

    private typealias SendCommand = @convention(c) (Int, UnsafeRawPointer?) -> Bool
    private static let sendCommand: SendCommand? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    /// Returns true only when output was active and a pause command was sent.
    /// The caller uses this to decide whether playback belongs to Whisperino
    /// to resume when the take ends.
    @discardableResult
    static func pauseIfAudioIsPlaying() -> Bool {
        guard defaultOutputIsRunning() else { return false }
        if sendCommand?(pauseCommand, nil) == true {
            return true
        }
        postMediaKey(playPauseKeyCode, isDown: true)
        postMediaKey(playPauseKeyCode, isDown: false)
        return true
    }

    static func resumePlayback() {
        if sendCommand?(playCommand, nil) == true { return }
        postMediaKey(playPauseKeyCode, isDown: true)
        postMediaKey(playPauseKeyCode, isDown: false)
    }

    private static func defaultOutputIsRunning() -> Bool {
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            0,
            nil,
            &deviceIDSize,
            &deviceID
        ) == noErr,
        deviceID != kAudioObjectUnknown else {
            return false
        }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &runningAddress,
            0,
            nil,
            &runningSize,
            &isRunning
        ) == noErr else {
            return false
        }
        return isRunning != 0
    }

    private static func postMediaKey(_ keyCode: Int, isDown: Bool) {
        let keyState = isDown ? 0xA : 0xB
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState << 8)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (keyCode << 16) | (keyState << 8),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
