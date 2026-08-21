import XCTest
@testable import Whisperino

final class AudioStreamHealthTests: XCTestCase {
    func testRunningEngineWithoutBuffersIsUnhealthy() {
        let health = AudioStreamHealth()
        XCTAssertEqual(health.startupFailure(engineIsRunning: true), .noBuffers)
    }

    func testAllZeroBuffersAreNotMistakenForQuietAnalogueInput() {
        var health = AudioStreamHealth()
        for _ in 0..<20 {
            health.observeBuffer(maxAbsoluteSample: 0)
        }
        XCTAssertEqual(health.startupFailure(engineIsRunning: true), .digitalSilence)
    }

    func testAnyNonZeroPCMProvesTheStreamIsLive() {
        var health = AudioStreamHealth()
        health.observeBuffer(maxAbsoluteSample: 0)
        health.observeBuffer(maxAbsoluteSample: 0.000_001)
        XCTAssertNil(health.startupFailure(engineIsRunning: true))
    }

    func testBufferCounterDetectsAStalledTap() {
        var health = AudioStreamHealth()
        health.observeBuffer(maxAbsoluteSample: 0.1)
        let checkpoint = health.bufferCount

        XCTAssertEqual(
            health.livenessFailure(
                engineIsRunning: true,
                previousBufferCount: checkpoint
            ),
            .stalled
        )
    }
}
