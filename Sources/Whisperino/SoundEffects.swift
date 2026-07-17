import AppKit
import AVFoundation

/// Plays short pleasant chimes when recording starts and stops.
/// Sounds are synthesized in memory (sine + envelope) so we don't need to ship audio files
/// and we can keep them tonally consistent. Respects the user's `soundEffectsEnabled` setting.
///
/// Rafterino mode brings its own soundtrack - a water splash on start and a
/// soft ship's bell on stop (both synthesized too). The mode implies the fun,
/// so these play whenever the flag is hoisted; the chime toggle keeps
/// governing only the plain chimes.
enum SoundEffects {
    private static let player = ChimePlayer()

    static func playStart() {
        if SettingsStore.shared.settings.rafterinoModeEnabled {
            player.play(.splash)
        } else if SettingsStore.shared.settings.soundEffectsEnabled {
            player.play(.start)
        }
    }

    static func playStop() {
        if SettingsStore.shared.settings.rafterinoModeEnabled {
            player.play(.bell)
        } else if SettingsStore.shared.settings.soundEffectsEnabled {
            player.play(.stop)
        }
    }
}

private enum ChimeKind {
    case start
    case stop
    case splash
    case bell
}

private final class ChimePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var startBuffer: AVAudioPCMBuffer?
    private var stopBuffer: AVAudioPCMBuffer?
    private var splashBuffer: AVAudioPCMBuffer?
    private var bellBuffer: AVAudioPCMBuffer?
    private let format: AVAudioFormat

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        // Two-tone chimes in the low register - felt more than heard.
        // Start: A3 → F3 (descending, "winding up")
        // Stop/submit: F3 → A3 (ascending, "submitted")
        startBuffer = synthesizeChime(notes: [(220, 0.10), (175, 0.20)], gap: 0.01)
        stopBuffer = synthesizeChime(notes: [(175, 0.10), (220, 0.20)], gap: 0.01)

        // Rafterino mode: a splash going in, a ship's bell coming out.
        splashBuffer = synthesizeSplash()
        bellBuffer = synthesizeBell()

        do {
            try engine.start()
            node.play()
        } catch {
            print("[whisperino] failed to start audio engine: \(error)")
        }
    }

    func play(_ kind: ChimeKind) {
        let buffer: AVAudioPCMBuffer?
        switch kind {
        case .start:  buffer = startBuffer
        case .stop:   buffer = stopBuffer
        case .splash: buffer = splashBuffer
        case .bell:   buffer = bellBuffer
        }
        guard let buffer else { return }
        if !engine.isRunning {
            try? engine.start()
            node.play()
        }
        node.scheduleBuffer(buffer, at: nil, options: .interruptsAtLoop, completionHandler: nil)
    }

    // MARK: - Rafterino sounds

    /// Water splash: a deep pitch-dropping "bloop" (the water swallowing
    /// what fell in) under an impact of white noise pushed through a
    /// one-pole lowpass whose cutoff sweeps from bright down to muffled -
    /// the "sploosh" darkening as the water closes.
    private func synthesizeSplash() -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let duration = 0.55
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return nil }

        let frames = Int(frameCount)
        // Deterministic noise - same splash every time, and no seeding
        // concerns. Cheap LCG.
        var rng: UInt64 = 0x5EAFA_F00D
        func whiteNoise() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: rng >> 11)) / Double(Int64.max)
        }

        var lowpassed = 0.0
        var bloopPhase = 0.0
        for f in 0..<frames {
            let t = Double(f) / sampleRate

            // Body "bloop" - the deep pitch-drop of water swallowing the
            // thing that fell in. This carries the "watery" character;
            // the noise on top is just the spray.
            let bloopEnv = t < 0.01 ? t / 0.01 : exp(-(t - 0.01) / 0.07)
            let bloopFreq = 320 * exp(-t * 6) + 130
            bloopPhase += 2 * .pi * bloopFreq / sampleRate
            var sample = sin(bloopPhase) * bloopEnv * 0.22

            // Spray: noise burst, 3ms attack then exponential decay.
            let impactEnv = t < 0.003 ? t / 0.003 : exp(-(t - 0.003) / 0.09)
            // Secondary slosh at ~180ms, softer and darker.
            let sloshEnv = t > 0.16 ? exp(-(t - 0.16) / 0.11) * 0.35 : 0
            // Lowpass sweep 3.8kHz → 600Hz over the first 250ms - dark
            // enough to read as water, not static.
            let cutoff = 600 + 3200 * max(0, 1 - t / 0.25)
            let a = 1 - exp(-2 * .pi * cutoff / sampleRate)
            lowpassed += a * (whiteNoise() - lowpassed)
            sample += lowpassed * (impactEnv + sloshEnv) * 0.45

            // Gentle master fade-out so the tail never clicks. Lands around
            // 0.2 peak - level with the bell on the way out.
            let master = min(1, (duration - t) / 0.05)
            channel[f] = Float(sample * master * 0.9)
        }
        return buffer
    }

    /// Ship's bell for "take's done": one soft strike. Bells are additive
    /// synthesis's home game - a handful of inharmonic metal partials, each
    /// as a slightly detuned pair (the pair beats, which is the shimmer of
    /// real bronze), dying away at their own rates. Tuned quiet and low -
    /// dockside at dusk, not the watch bell.
    private func synthesizeBell() -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let duration = 0.6
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return nil }

        let frames = Int(frameCount)
        let f0 = 620.0
        // (frequency ratio, amplitude, decay tau in seconds) - higher
        // partials ring brighter but die faster, like real metal. Short
        // taus: one brief glint, gone in half a second.
        let partials: [(Double, Double, Double)] = [
            (1.00, 1.00, 0.22),
            (2.72, 0.40, 0.12),
            (5.44, 0.14, 0.06),
            (8.35, 0.06, 0.04),
        ]

        for f in 0..<frames {
            let t = Double(f) / sampleRate
            var sample = 0.0
            for (ratio, amp, tau) in partials {
                let freq = f0 * ratio
                // Detuned pair - 0.4% apart, beating at ~2.5Hz.
                sample += (sin(2 * .pi * freq * 0.998 * t) + sin(2 * .pi * freq * 1.002 * t))
                    * 0.5 * amp * exp(-t / tau)
            }
            // 2ms attack keeps the strike from clicking; master fade so the
            // long tail ends at true zero.
            let attack = min(1, t / 0.002)
            let master = min(1, (duration - t) / 0.08)
            channel[f] = Float(sample * attack * master * 0.10)
        }
        return buffer
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

        let attack = 0.020   // 20ms attack - soft, no click
        let releaseTarget = 0.18   // ideal release; clamped per-note below

        var cursor = 0
        var phase = 0.0
        let twoPi = 2.0 * .pi
        let amplitude = 0.09  // very subtle - felt more than heard

        for (i, (freq, duration)) in notes.enumerated() {
            let frames = Int(sampleRate * duration)
            let phaseIncrement = twoPi * freq / sampleRate
            // Clamp release so it fits within (duration - attack). Without this,
            // a note shorter than `releaseTarget` causes a discontinuity at the
            // end of the attack - audible as a click on the first note.
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
