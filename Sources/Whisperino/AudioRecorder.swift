import AVFoundation
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempURL: URL?
    private var smoothedLevel: Float = 0
    private var isPaused = false

    func start(levelCallback: @escaping (Float) -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("whisperino_\(UUID().uuidString).wav")
        self.tempURL = url
        smoothedLevel = 0
        isPaused = false

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let audioFile = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
        self.audioFile = audioFile

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // When paused, keep engine running but skip writing and report zero level
            guard !self.isPaused else {
                levelCallback(0)
                return
            }

            // Calculate RMS and convert to a visible 0..1 range
            if let channelData = buffer.floatChannelData {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames {
                    let sample = channelData[0][i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / max(Float(frames), 1))

                // Convert to decibels, then normalize to 0..1
                // More sensitive: -60dB=0, -15dB=1
                let db = 20 * log10(max(rms, 1e-6))
                let normalized = max(0, min(1, (db + 60) / 45))

                // Smooth: fast attack, slow decay
                let attack: Float = 0.7
                let decay: Float = 0.2
                let factor = normalized > self.smoothedLevel ? attack : decay
                self.smoothedLevel += factor * (normalized - self.smoothedLevel)

                levelCallback(self.smoothedLevel)
            }

            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                print("[whisperino] audio write error: \(error.localizedDescription)")
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    func stop() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        let url = tempURL
        tempURL = nil
        return url
    }
}
