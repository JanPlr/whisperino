import AVFoundation
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempURL: URL?

    func start(levelCallback: @escaping (Float) -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("whisperflow_\(UUID().uuidString).wav")
        self.tempURL = url

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Record in native format - whisper.cpp handles resampling
        let audioFile = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
        self.audioFile = audioFile

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Calculate RMS audio level
            if let channelData = buffer.floatChannelData {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames {
                    let sample = channelData[0][i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / max(Float(frames), 1))
                levelCallback(rms)
            }

            // Write buffer to file
            do {
                try self?.audioFile?.write(from: buffer)
            } catch {
                // Silently skip write errors for individual buffers
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    func stop() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        return tempURL
    }
}
