import AVFoundation
import Foundation
import SherpaOnnx
import SpeakerFilteringCore

private enum WorkerError: LocalizedError {
    case badArguments(String)
    case audioUnavailable
    case modelUnavailable(String)
    case insufficientEnrollment
    case inconsistentEnrollment

    var errorDescription: String? {
        switch self {
        case .badArguments(let message): return message
        case .audioUnavailable: return "The enrollment audio could not be read"
        case .modelUnavailable(let name): return "The speaker model could not be loaded: \(name)"
        case .insufficientEnrollment: return "Not enough clear speech was captured"
        case .inconsistentEnrollment: return "The voice samples were too inconsistent; record again in a quiet room"
        }
    }
}

private struct WorkerArguments {
    let command: String
    let audioURL: URL
    let segmentationModel: String
    let embeddingModel: String
    let profileURL: URL?
    let outputURL: URL?

    init(_ arguments: [String]) throws {
        guard arguments.count >= 2 else { throw WorkerError.badArguments("Missing command") }
        command = arguments[1]
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let audio = value("--audio"),
              let segmentation = value("--segmentation-model"),
              let embedding = value("--embedding-model") else {
            throw WorkerError.badArguments("Missing model or audio path")
        }
        audioURL = URL(fileURLWithPath: audio)
        segmentationModel = segmentation
        embeddingModel = embedding
        profileURL = value("--profile").map { URL(fileURLWithPath: $0) }
        outputURL = value("--output").map { URL(fileURLWithPath: $0) }
    }
}

private enum AudioLoader {
    static let sampleRate = 16_000
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
    )!

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard file.length > 0,
              let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ) else { throw WorkerError.audioUnavailable }
        try file.read(into: input)
        if inputFormat.sampleRate == Double(sampleRate),
           inputFormat.channelCount == 1,
           inputFormat.commonFormat == .pcmFormatFloat32 {
            return floats(input)
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw WorkerError.audioUnavailable
        }
        let ratio = Double(sampleRate) / max(inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw WorkerError.audioUnavailable
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if consumed {
                state.pointee = .endOfStream
                return nil
            }
            consumed = true
            state.pointee = .haveData
            return input
        }
        guard status != .error else { throw conversionError ?? WorkerError.audioUnavailable }
        return floats(output)
    }

    private static func floats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return [] }
        if buffer.format.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        var output = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(buffer.format.channelCount)
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<frames { output[frame] += channels[channel][frame] * scale }
        }
        return output
    }
}

private final class SpeakerEngine {
    private let samples: [Float]
    private let diarizer: SherpaOnnxOfflineSpeakerDiarizationWrapper
    private let extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper

    init(samples: [Float], segmentationModel: String, embeddingModel: String, oneSpeaker: Bool) throws {
        self.samples = samples
        var embeddingConfig = sherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: embeddingModel,
            numThreads: 2,
            provider: "cpu"
        )
        extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &embeddingConfig)
        guard extractor.impl != nil, extractor.dim > 0 else {
            throw WorkerError.modelUnavailable("embedding")
        }

        let segmentation = sherpaOnnxOfflineSpeakerSegmentationModelConfig(
            pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                model: segmentationModel,
                // Upstream's quality-oriented default. Smaller shifts add
                // overlap (and compute) but improve boundary consistency.
                windowShiftRatio: 0.1
            ),
            numThreads: 2,
            provider: "cpu"
        )
        let clustering = oneSpeaker
            ? sherpaOnnxFastClusteringConfig(numClusters: 1)
            : sherpaOnnxFastClusteringConfig(numClusters: -1, threshold: 0.70)
        var diarizationConfig = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: segmentation,
            embedding: embeddingConfig,
            clustering: clustering,
            minDurationOn: 0.25,
            minDurationOff: 0.30
        )
        diarizer = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &diarizationConfig)
        guard diarizer.impl != nil else { throw WorkerError.modelUnavailable("segmentation") }
    }

    func enrollmentProfile(modelFileName: String) throws -> SpeakerVoiceProfile {
        let turns = diarizer.process(samples: samples)
        let speech = concatenate(turns: turns, speaker: nil, exclusiveOnly: false)
        guard speech.count >= 8 * AudioLoader.sampleRate else {
            throw WorkerError.insufficientEnrollment
        }
        let chunkLength = speech.count / 3
        var embeddings: [[Float]] = []
        for index in 0..<3 {
            let start = index * chunkLength
            let end = index == 2 ? speech.count : (index + 1) * chunkLength
            let chunk = Array(speech[start..<end])
            if let embedding = embedding(chunk) { embeddings.append(embedding) }
        }
        guard embeddings.count == 3 else { throw WorkerError.insufficientEnrollment }
        var pairScores: [Float] = []
        for first in 0..<(embeddings.count - 1) {
            for second in (first + 1)..<embeddings.count {
                pairScores.append(SpeakerMath.cosine(embeddings[first], embeddings[second]))
            }
        }
        guard let weakest = pairScores.min(), weakest >= 0.20 else {
            throw WorkerError.inconsistentEnrollment
        }
        let threshold = min(0.48, max(0.34, weakest - 0.12))
        return SpeakerVoiceProfile(
            modelFileName: modelFileName,
            embeddings: embeddings,
            centroid: SpeakerMath.centroid(embeddings),
            acceptanceThreshold: threshold
        )
    }

    func analyze(profile: SpeakerVoiceProfile) -> SpeakerAnalysis {
        let turns = diarizer.process(samples: samples)
        let speakers = Set(turns.map(\.speaker)).sorted()
        guard !speakers.isEmpty else {
            return SpeakerAnalysis(disposition: .inconclusive, reason: "No diarized speech")
        }

        var scores: [(speaker: Int, score: Float)] = []
        for speaker in speakers {
            var speech = concatenate(turns: turns, speaker: speaker, exclusiveOnly: true)
            if speech.count < 2 * AudioLoader.sampleRate {
                speech = concatenate(turns: turns, speaker: speaker, exclusiveOnly: false)
            }
            guard let observed = embedding(speech) else { continue }
            let centroidScore = SpeakerMath.cosine(profile.centroid, observed)
            let exemplarScore = profile.embeddings.map { SpeakerMath.cosine($0, observed) }.max() ?? -1
            scores.append((speaker, 0.7 * centroidScore + 0.3 * exemplarScore))
        }
        scores.sort { $0.score > $1.score }
        guard let best = scores.first else {
            return SpeakerAnalysis(
                disposition: .inconclusive,
                speakerCount: speakers.count,
                reason: "Speaker embeddings were unavailable"
            )
        }
        let runnerUp = scores.dropFirst().first?.score
        let margin = best.score - (runnerUp ?? -1)
        let confidentlyMatched = best.score >= profile.acceptanceThreshold
            && (speakers.count == 1 || margin >= 0.06)
        if confidentlyMatched {
            let ranges = turns
                .filter { $0.speaker == best.speaker }
                .map {
                    SpeakerTimeRange(
                        startMs: Int64(($0.start * 1000).rounded()),
                        endMs: Int64(($0.end * 1000).rounded())
                    )
                }
            return SpeakerAnalysis(
                disposition: .matched,
                targetRanges: ranges,
                bestScore: best.score,
                runnerUpScore: runnerUp,
                speakerCount: speakers.count,
                reason: "Target speaker matched"
            )
        }

        let strongNegativeThreshold = max(0.15, profile.acceptanceThreshold - 0.18)
        let diarizedMs = turns.reduce(Int64(0)) {
            $0 + Int64(max(0, ($1.end - $1.start) * 1000))
        }
        if best.score < strongNegativeThreshold, diarizedMs >= 2_000 {
            return SpeakerAnalysis(
                disposition: .noTarget,
                bestScore: best.score,
                runnerUpScore: runnerUp,
                speakerCount: speakers.count,
                reason: "Only non-target speech was detected"
            )
        }
        return SpeakerAnalysis(
            disposition: .inconclusive,
            bestScore: best.score,
            runnerUpScore: runnerUp,
            speakerCount: speakers.count,
            reason: "Speaker match was ambiguous"
        )
    }

    private func embedding(_ speech: [Float]) -> [Float]? {
        guard speech.count >= AudioLoader.sampleRate else { return nil }
        let stream = extractor.createStream()
        stream.acceptWaveform(samples: speech, sampleRate: AudioLoader.sampleRate)
        stream.inputFinished()
        let result = extractor.compute(stream: stream)
        return result.isEmpty ? nil : SpeakerMath.normalized(result)
    }

    private func concatenate(
        turns: [SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper],
        speaker: Int?,
        exclusiveOnly: Bool
    ) -> [Float] {
        let frameSamples = AudioLoader.sampleRate / 50 // 20 ms
        let frameCount = max(1, (samples.count + frameSamples - 1) / frameSamples)
        var active = [[Int]](repeating: [], count: frameCount)
        for turn in turns {
            let start = max(0, Int(floor(turn.start * 50)))
            let end = min(frameCount, Int(ceil(turn.end * 50)))
            guard start < end else { continue }
            for frame in start..<end where !active[frame].contains(turn.speaker) {
                active[frame].append(turn.speaker)
            }
        }
        var output: [Float] = []
        output.reserveCapacity(samples.count)
        var previousIncluded = false
        for frame in 0..<frameCount {
            let include: Bool
            if let speaker {
                include = active[frame].contains(speaker) && (!exclusiveOnly || active[frame].count == 1)
            } else {
                include = !active[frame].isEmpty
            }
            if include {
                if !previousIncluded, !output.isEmpty {
                    output.append(contentsOf: repeatElement(0, count: AudioLoader.sampleRate / 20))
                }
                let start = frame * frameSamples
                let end = min(samples.count, start + frameSamples)
                if start < end { output.append(contentsOf: samples[start..<end]) }
            }
            previousIncluded = include
        }
        return output
    }
}

private func emit<T: Encodable>(_ value: T, outputURL: URL?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    if let outputURL {
        try data.write(to: outputURL, options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}

do {
    let arguments = try WorkerArguments(CommandLine.arguments)
    let samples = try AudioLoader.load(arguments.audioURL)
    switch arguments.command {
    case "enroll":
        let engine = try SpeakerEngine(
            samples: samples,
            segmentationModel: arguments.segmentationModel,
            embeddingModel: arguments.embeddingModel,
            oneSpeaker: true
        )
        try emit(try engine.enrollmentProfile(
            modelFileName: URL(fileURLWithPath: arguments.embeddingModel).lastPathComponent
        ), outputURL: arguments.outputURL)
    case "analyze":
        guard let profileURL = arguments.profileURL else {
            throw WorkerError.badArguments("Missing profile")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(
            SpeakerVoiceProfile.self,
            from: Data(contentsOf: profileURL)
        )
        let engine = try SpeakerEngine(
            samples: samples,
            segmentationModel: arguments.segmentationModel,
            embeddingModel: arguments.embeddingModel,
            oneSpeaker: false
        )
        try emit(engine.analyze(profile: profile), outputURL: arguments.outputURL)
    default:
        throw WorkerError.badArguments("Unknown command: \(arguments.command)")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
