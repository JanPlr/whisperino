import AVFoundation
import XCTest
@testable import Whisperino

final class AudioPCMTests: XCTestCase {
    func testLoadMono16kReadsFloatSamples() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperino-pcm-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AudioPCM.mono16kFormat
        let frames = 1_600
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for i in 0..<frames {
            channel[i] = sin(Float(i) * 0.1) * 0.5
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let samples = try AudioPCM.loadMono16k(from: url)
        XCTAssertEqual(samples.count, frames)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
    }

    func testConverterDownmixesAndResamples() throws {
        let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let frames: AVAudioFrameCount = 480
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = 0.4
            }
        }

        let converter = AVAudioConverter(from: input, to: AudioPCM.mono16kFormat)!
        let samples = AudioPCM.convert(buffer, using: converter)
        XCTAssertGreaterThan(samples.count, 140)
        XCTAssertLessThan(samples.count, 200)
        XCTAssertEqual(samples[samples.count / 2], 0.4, accuracy: 0.05)
    }
}
