import XCTest
@testable import Whisperino

final class ASRModelTests: XCTestCase {
    func testCatalogHasTheShippedModels() {
        XCTAssertEqual(
            ASRModelCatalog.all.map(\.id),
            [.parakeetV3, .nemotron35, .whisperTurbo, .whisperLargeV3]
        )
        XCTAssertEqual(ASRModelCatalog.default, .parakeetV3)
        XCTAssertTrue(ASRModelCatalog.descriptor(for: .nemotron35).supportsStreaming)
        XCTAssertFalse(ASRModelCatalog.descriptor(for: .whisperTurbo).supportsStreaming)
        XCTAssertFalse(ASRModelCatalog.descriptor(for: .whisperLargeV3).supportsStreaming)
        XCTAssertFalse(ASRModelCatalog.descriptor(for: .parakeetV3).supportsStreaming)
    }

    func testHuggingFaceURLsPointAtOfficialGGUFs() {
        let nemotron = ASRModelCatalog.descriptor(for: .nemotron35)
        XCTAssertEqual(nemotron.downloadURL.host, "huggingface.co")
        XCTAssertTrue(nemotron.downloadURL.path.contains("handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf"))
        XCTAssertTrue(nemotron.fileName.hasSuffix(".gguf"))

        let whisper = ASRModelCatalog.descriptor(for: .whisperTurbo)
        XCTAssertTrue(whisper.downloadURL.path.contains("handy-computer/whisper-large-v3-turbo-gguf"))

        let whisperLarge = ASRModelCatalog.descriptor(for: .whisperLargeV3)
        XCTAssertTrue(whisperLarge.downloadURL.path.contains("handy-computer/whisper-large-v3-gguf"))
        XCTAssertTrue(whisperLarge.fileName.contains("whisper-large-v3-Q8_0"))
        XCTAssertFalse(whisperLarge.fileName.contains("turbo"))

        let parakeet = ASRModelCatalog.descriptor(for: .parakeetV3)
        XCTAssertTrue(parakeet.downloadURL.path.contains("handy-computer/parakeet-tdt-0.6b-v3-gguf"))
    }

    func testNemotronMapsISOCodesToLocales() {
        let german = ASRModelCatalog.recognitionLanguage(for: .nemotron35, selectedCodes: ["de"])
        XCTAssertEqual(german.language, "de-DE")
        XCTAssertNil(german.prompt)

        let auto = ASRModelCatalog.recognitionLanguage(for: .nemotron35, selectedCodes: [])
        XCTAssertNil(auto.language)

        let mixed = ASRModelCatalog.recognitionLanguage(for: .nemotron35, selectedCodes: ["en", "de"])
        XCTAssertNil(mixed.language)
    }

    func testWhisperKeepsISOCodesAndPromptForSeveralLanguages() {
        let one = ASRModelCatalog.recognitionLanguage(for: .whisperTurbo, selectedCodes: ["fr"])
        XCTAssertEqual(one.language, "fr")
        XCTAssertNil(one.prompt)

        let several = ASRModelCatalog.recognitionLanguage(for: .whisperTurbo, selectedCodes: ["en", "de"])
        XCTAssertEqual(several.language, "auto")
        XCTAssertNotNil(several.prompt)
        XCTAssertTrue(several.prompt?.contains("English") == true)

        let large = ASRModelCatalog.recognitionLanguage(for: .whisperLargeV3, selectedCodes: ["de"])
        XCTAssertEqual(large.language, "de")
        XCTAssertNil(large.prompt)
    }

    func testParakeetRequiresAConcreteLanguageHint() {
        let empty = ASRModelCatalog.recognitionLanguage(for: .parakeetV3, selectedCodes: [])
        XCTAssertEqual(empty.language, "en")

        let german = ASRModelCatalog.recognitionLanguage(for: .parakeetV3, selectedCodes: ["de"])
        XCTAssertEqual(german.language, "de")

        let japanese = ASRModelCatalog.recognitionLanguage(for: .parakeetV3, selectedCodes: ["ja"])
        XCTAssertEqual(japanese.language, "en")
    }

    func testSettingsDecodeSelectedSpeechModel() throws {
        let json = Data("""
        {"asrModel":"whisperTurbo","llmRefinementEnabled":false,"aiModeEnabled":false}
        """.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(settings.asrModel, .whisperTurbo)

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.asrModel, .parakeetV3)
    }

    func testLocalModelPathLivesUnderWhisperinoModels() {
        let home = URL(fileURLWithPath: "/tmp/whisperino-home")
        let url = ASRModelCatalog.localURL(for: .nemotron35, relativeTo: home)
        XCTAssertEqual(
            url.path,
            "/tmp/whisperino-home/.whisperino/models/nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf"
        )
    }

    func testCleanOutputStripsWhisperTokens() {
        XCTAssertEqual(Transcriber.cleanOutput("  hello [EOT] [_TT_12] "), "hello")
    }
}
