import Foundation

public struct SpeakerTimeRange: Codable, Equatable, Sendable {
    public let startMs: Int64
    public let endMs: Int64

    public init(startMs: Int64, endMs: Int64) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMs: Int64 { max(0, endMs - startMs) }
}

public struct TimedTranscriptUnit: Equatable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public let text: String

    public init(startMs: Int64, endMs: Int64, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public struct SpeakerVoiceProfile: Codable, Equatable, Sendable {
    public let version: Int
    public let modelFileName: String
    public let embeddings: [[Float]]
    public let centroid: [Float]
    public let acceptanceThreshold: Float
    public let createdAt: Date

    public init(
        version: Int = 2,
        modelFileName: String,
        embeddings: [[Float]],
        centroid: [Float],
        acceptanceThreshold: Float,
        createdAt: Date = Date()
    ) {
        self.version = version
        self.modelFileName = modelFileName
        self.embeddings = embeddings
        self.centroid = centroid
        self.acceptanceThreshold = acceptanceThreshold
        self.createdAt = createdAt
    }
}

public enum SpeakerAnalysisDisposition: String, Codable, Sendable {
    case matched
    case noTarget
    case inconclusive
}

public struct SpeakerAnalysis: Codable, Equatable, Sendable {
    public let disposition: SpeakerAnalysisDisposition
    public let targetRanges: [SpeakerTimeRange]
    public let bestScore: Float?
    public let runnerUpScore: Float?
    public let speakerCount: Int
    public let reason: String

    public init(
        disposition: SpeakerAnalysisDisposition,
        targetRanges: [SpeakerTimeRange] = [],
        bestScore: Float? = nil,
        runnerUpScore: Float? = nil,
        speakerCount: Int = 0,
        reason: String
    ) {
        self.disposition = disposition
        self.targetRanges = targetRanges
        self.bestScore = bestScore
        self.runnerUpScore = runnerUpScore
        self.speakerCount = speakerCount
        self.reason = reason
    }
}

/// Pure timestamp policy shared by the app and tests. Inconclusive analysis is
/// deliberately fail-open. A confident no-target result is the only outcome
/// allowed to produce an empty transcript.
public enum SpeakerTranscriptSelector {
    public static func select(
        fullText: String,
        units: [TimedTranscriptUnit],
        analysis: SpeakerAnalysis?
    ) -> String {
        guard let analysis else { return fullText }
        switch analysis.disposition {
        case .inconclusive:
            return fullText
        case .noTarget:
            return ""
        case .matched:
            guard !units.isEmpty, !analysis.targetRanges.isEmpty else { return fullText }
            let selected = units.filter { unit in
                let duration = max(1, unit.endMs - unit.startMs)
                let overlap = analysis.targetRanges.reduce(Int64(0)) { total, range in
                    total + max(0, min(unit.endMs, range.endMs) - max(unit.startMs, range.startMs))
                }
                let midpoint = unit.startMs + duration / 2
                let midpointMatches = analysis.targetRanges.contains {
                    midpoint >= $0.startMs && midpoint <= $0.endMs
                }
                return midpointMatches || Double(overlap) / Double(duration) >= 0.45
            }
            let joined = joinTranscriptUnits(selected.map(\.text))
            // A confident target with no aligned text usually means timestamp
            // granularity was insufficient. Preserve the normal transcript.
            return joined.isEmpty ? fullText : joined
        }
    }

    public static func joinTranscriptUnits(_ values: [String]) -> String {
        values.reduce(into: "") { result, raw in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if result.isEmpty || raw.first?.isWhitespace == true {
                result += text
            } else if text.first.map({ ",.!?:;)]}".contains($0) }) == true {
                result += text
            } else {
                result += " " + text
            }
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SpeakerMath {
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot: Float = 0
        var left: Float = 0
        var right: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        guard left > 0, right > 0 else { return -1 }
        return dot / sqrt(left * right)
    }

    public static func normalized(_ values: [Float]) -> [Float] {
        let magnitude = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return values }
        return values.map { $0 / magnitude }
    }

    public static func centroid(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var average = [Float](repeating: 0, count: first.count)
        for embedding in embeddings where embedding.count == average.count {
            for index in average.indices { average[index] += embedding[index] }
        }
        return normalized(average)
    }
}
