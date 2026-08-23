import AVFoundation
import Foundation

/// transcribe.cpp wants 16 kHz mono float32 in [-1, 1]. The mic tap is
/// whatever CoreAudio reports (often 48 kHz stereo), and leftover WAVs from
/// chunk rotation are the same, so every path goes through this converter.
enum AudioPCM {
    static let sampleRate: Double = 16_000

    static var mono16kFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Convert one tap buffer. `converter` is reused across callbacks so the
    /// resampler keeps its filter state.
    static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) -> [Float] {
        let ratio = converter.outputFormat.sampleRate / max(converter.inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return []
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            return []
        }
        return floats(from: output)
    }

    static func loadMono16k(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0 else { return [] }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw TranscriberError.noOutput
        }
        try file.read(into: input)

        if format.sampleRate == sampleRate,
           format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32 {
            return floats(from: input)
        }

        guard let converter = AVAudioConverter(from: format, to: mono16kFormat) else {
            throw TranscriberError.noOutput
        }
        return convert(input, using: converter)
    }

    static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        if channelCount <= 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        var mixed = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channelCount)
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frames {
                mixed[frame] += samples[frame] * scale
            }
        }
        return mixed
    }
}
