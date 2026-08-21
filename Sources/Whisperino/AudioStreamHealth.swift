import Foundation

/// Small, deterministic state machine for the two failure signatures seen in
/// the field with Bluetooth microphones:
///
/// 1. AVAudioEngine starts, but its tap never receives a buffer.
/// 2. The tap runs normally, but every PCM sample is exactly zero.
///
/// A normal quiet microphone still has a non-zero analogue noise floor. Exact
/// digital zero across many buffers is therefore materially different from a
/// user simply pausing before speaking.
struct AudioStreamHealth: Equatable {
    enum Failure: Equatable {
        case engineStopped
        case noBuffers
        case digitalSilence
        case stalled
    }

    private(set) var bufferCount: UInt64 = 0
    private(set) var hasNonZeroPCM = false

    mutating func observeBuffer(maxAbsoluteSample: Float) {
        bufferCount &+= 1
        if maxAbsoluteSample > 0 {
            hasNonZeroPCM = true
        }
    }

    func startupFailure(engineIsRunning: Bool) -> Failure? {
        guard engineIsRunning else { return .engineStopped }
        guard bufferCount > 0 else { return .noBuffers }
        guard hasNonZeroPCM else { return .digitalSilence }
        return nil
    }

    func livenessFailure(
        engineIsRunning: Bool,
        previousBufferCount: UInt64
    ) -> Failure? {
        guard engineIsRunning else { return .engineStopped }
        guard bufferCount != previousBufferCount else { return .stalled }
        return nil
    }

    mutating func reset() {
        self = AudioStreamHealth()
    }
}
