import AppKit
import AVFoundation

/// Plays short pleasant chimes when recording starts and stops.
/// Sounds are synthesized in memory (sine + envelope) so we don't need to ship audio files
/// and we can keep them tonally consistent. Respects the user's `soundEffectsEnabled` setting.
enum SoundEffects {
    private static let player = ChimePlayer()

    static func playStart() {
        guard SettingsStore.shared.settings.soundEffectsEnabled else { return }
        player.play(.start)
    }

    static func playStop() {
        guard SettingsStore.shared.settings.soundEffectsEnabled else { return }
        player.play(.stop)
    }
}

private enum ChimeKind {
    case start
    case stop
}

private final class ChimePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var startBuffer: AVAudioPCMBuffer?
    private var stopBuffer: AVAudioPCMBuffer?
    private let format: AVAudioFormat

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        // Two-tone chimes in the low register — felt more than heard.
        // Start: A3 → F3 (descending, "winding up")
        // Stop/submit: F3 → A3 (ascending, "submitted")
        startBuffer = synthesizeChime(notes: [(220, 0.10), (175, 0.20)], gap: 0.01)
        stopBuffer = synthesizeChime(notes: [(175, 0.10), (220, 0.20)], gap: 0.01)

        do {
            try engine.start()
            node.play()
        } catch {
            print("[whisperino] failed to start audio engine: \(error)")
        }
    }

    func play(_ kind: ChimeKind) {
        guard let buffer = (kind == .start ? startBuffer : stopBuffer) else { return }
        if !engine.isRunning {
            try? engine.start()
            node.play()
        }
        node.scheduleBuffer(buffer, at: nil, options: .interruptsAtLoop, completionHandler: nil)
    }

    /// Synthesize a sequence of sine-wave notes with attack/release envelopes.
    /// Each note: (frequency in Hz, duration in seconds). `gap` is silence between notes.
    private func synthesizeChime(notes: [(Double, Double)], gap: Double) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let totalDuration = notes.reduce(0.0) { $0 + $1.1 } + gap * Double(max(0, notes.count - 1))
        let frameCount = AVAudioFrameCount(sampleRate * totalDuration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return nil }

        let attack = 0.020   // 20ms attack — soft, no click
        let releaseTarget = 0.18   // ideal release; clamped per-note below

        var cursor = 0
        var phase = 0.0
        let twoPi = 2.0 * .pi
        let amplitude = 0.09  // very subtle — felt more than heard

        for (i, (freq, duration)) in notes.enumerated() {
            let frames = Int(sampleRate * duration)
            let phaseIncrement = twoPi * freq / sampleRate
            // Clamp release so it fits within (duration - attack). Without this,
            // a note shorter than `releaseTarget` causes a discontinuity at the
            // end of the attack — audible as a click on the first note.
            let release = max(0.005, min(releaseTarget, duration - attack))

            for f in 0..<frames {
                let t = Double(f) / sampleRate
                let env: Double
                if t < attack {
                    env = t / attack
                } else if t > duration - release {
                    let r = (duration - t) / release
                    env = max(0, r * r)  // exponential-ish decay
                } else {
                    env = 1
                }
                channel[cursor] = Float(sin(phase) * env * amplitude)
                phase += phaseIncrement
                if phase > twoPi { phase -= twoPi }
                cursor += 1
            }

            // Silent gap between notes
            if i < notes.count - 1 {
                let gapFrames = Int(sampleRate * gap)
                for _ in 0..<gapFrames {
                    channel[cursor] = 0
                    cursor += 1
                }
            }
        }

        return buffer
    }
}
