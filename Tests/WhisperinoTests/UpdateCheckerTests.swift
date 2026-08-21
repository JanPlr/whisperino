import XCTest
@testable import Whisperino

final class UpdateCheckerTests: XCTestCase {
    func testReleaseFeedChoosesHighestSemanticVersion() throws {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed>
          <entry><link href="https://github.com/JanPlr/whisperino/releases/tag/v3.0.1"/></entry>
          <entry><link href="https://github.com/JanPlr/whisperino/releases/tag/v3.0.10"/></entry>
          <entry><link href="https://github.com/JanPlr/whisperino/releases/tag/v2.9.9"/></entry>
        </feed>
        """

        let release = try XCTUnwrap(
            UpdateChecker.parseLatestReleaseFeed(Data(feed.utf8))
        )

        XCTAssertEqual(release.version, "3.0.10")
        XCTAssertEqual(
            release.assetURL.absoluteString,
            "https://github.com/JanPlr/whisperino/releases/download/v3.0.10/Whisperino-v3.0.10.zip"
        )
    }

    func testRateLimitJSONCannotMasqueradeAsUpToDateFeed() {
        let errorPayload = #"{"message":"API rate limit exceeded"}"#
        XCTAssertNil(UpdateChecker.parseLatestReleaseFeed(Data(errorPayload.utf8)))
    }

    func testEmptyFeedIsRejected() {
        XCTAssertNil(UpdateChecker.parseLatestReleaseFeed(Data("<feed/>".utf8)))
    }
}
