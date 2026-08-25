import XCTest
import SpeakerFilteringCore
@testable import Whisperino

final class SpeakerFilteringPolicyTests: XCTestCase {
    func testDisabledOrFailedAnalysisReturnsNormalTranscriptExactly() {
        let full = "This is the normal transcript."
        let units = [TimedTranscriptUnit(startMs: 0, endMs: 1000, text: full)]
        XCTAssertEqual(
            SpeakerTranscriptSelector.select(fullText: full, units: units, analysis: nil),
            full
        )
        XCTAssertEqual(
            SpeakerTranscriptSelector.select(
                fullText: full,
                units: units,
                analysis: SpeakerAnalysis(disposition: .inconclusive, reason: "timeout")
            ),
            full
        )
    }

    func testMatchedSpeakerSelectsOnlyOverlappingWords() {
        let units = [
            TimedTranscriptUnit(startMs: 0, endMs: 500, text: "background"),
            TimedTranscriptUnit(startMs: 600, endMs: 900, text: "hello"),
            TimedTranscriptUnit(startMs: 900, endMs: 1_300, text: " world"),
        ]
        let analysis = SpeakerAnalysis(
            disposition: .matched,
            targetRanges: [SpeakerTimeRange(startMs: 550, endMs: 1_400)],
            bestScore: 0.7,
            speakerCount: 2,
            reason: "matched"
        )
        XCTAssertEqual(
            SpeakerTranscriptSelector.select(
                fullText: "background hello world",
                units: units,
                analysis: analysis
            ),
            "hello world"
        )
    }

    func testEmptyTimestampAlignmentFailsOpen() {
        let full = "Keep me when timestamps are unavailable"
        let analysis = SpeakerAnalysis(
            disposition: .matched,
            targetRanges: [SpeakerTimeRange(startMs: 0, endMs: 1000)],
            reason: "matched"
        )
        XCTAssertEqual(
            SpeakerTranscriptSelector.select(fullText: full, units: [], analysis: analysis),
            full
        )
    }

    func testConfidentNoTargetCanReturnEmpty() {
        XCTAssertEqual(
            SpeakerTranscriptSelector.select(
                fullText: "someone else",
                units: [TimedTranscriptUnit(startMs: 0, endMs: 1000, text: "someone else")],
                analysis: SpeakerAnalysis(disposition: .noTarget, reason: "strong negative")
            ),
            ""
        )
    }

    func testVoiceFilterSettingMigratesOff() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.voiceIsolationEnabled)
    }
}
