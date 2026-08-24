import AppKit
import XCTest
@testable import Whisperino

final class TriggerShortcutTests: XCTestCase {
    func testPresetsMatchLegacyBehaviour() {
        XCTAssertEqual(TriggerShortcut.fn.shortLabel, "fn")
        XCTAssertFalse(TriggerShortcut.fn.isCombo)
        XCTAssertTrue(TriggerShortcut.fn.isDown(in: .function))
        XCTAssertFalse(TriggerShortcut.fn.isDown(in: .option))
        XCTAssertTrue(TriggerShortcut.fn.blockedFlags.contains(.option))

        XCTAssertEqual(TriggerShortcut.optionD.shortLabel, "⌥D")
        XCTAssertEqual(TriggerShortcut.optionD.comboKeyCode, 2)
        XCTAssertTrue(TriggerShortcut.optionD.isDown(in: .option))
        XCTAssertFalse(TriggerShortcut.optionD.blockedFlags.contains(.option))
        XCTAssertTrue(TriggerShortcut.optionD.blockedFlags.contains(.command))
    }

    func testFnPlusSpaceLabelAndMatching() {
        let shortcut = TriggerShortcut(
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            keyCode: 49
        )
        XCTAssertEqual(shortcut.shortLabel, "fn + space")
        XCTAssertTrue(shortcut.isCombo)
        XCTAssertEqual(TriggerShortcut.fnSpace, shortcut)
        XCTAssertTrue(shortcut.isDown(in: [.function, .shift]))
        XCTAssertFalse(shortcut.isDown(in: .option))
    }

    func testMigratesLegacyTriggerKeyStrings() throws {
        let fn = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"triggerKey":"fn"}"#.utf8))
        XCTAssertEqual(fn.triggerKey, .fn)

        let optionD = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"triggerKey":"optionD"}"#.utf8)
        )
        XCTAssertEqual(optionD.triggerKey, .optionD)

        let retired = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"triggerKey":"optionQ"}"#.utf8)
        )
        XCTAssertEqual(retired.triggerKey, .fn)
    }

    func testDecodesCustomShortcutObject() throws {
        let flags = NSEvent.ModifierFlags.function.rawValue
        let json = Data(#"{"triggerKey":{"modifierFlags":\#(flags),"keyCode":49}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(settings.triggerKey.shortLabel, "fn + space")
        XCTAssertEqual(settings.triggerKey.keyCode, 49)
    }

    func testRoundTripCustomShortcut() throws {
        var settings = AppSettings()
        settings.triggerKey = TriggerShortcut(
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            keyCode: 49
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.triggerKey, settings.triggerKey)
    }

    func testRecordingActivationDefaultsToHold() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{}"#.utf8))
        XCTAssertEqual(settings.recordingActivation, .hold)
        XCTAssertEqual(settings.triggerKey, .fn)
    }

    func testSelectActivationSwapsModeDefaultsOnly() {
        var settings = AppSettings()
        XCTAssertEqual(settings.triggerKey, .fn)

        settings.selectActivation(.tap)
        XCTAssertEqual(settings.recordingActivation, .tap)
        XCTAssertEqual(settings.triggerKey, .fnSpace)

        settings.selectActivation(.hold)
        XCTAssertEqual(settings.triggerKey, .fn)

        settings.triggerKey = .optionD
        settings.selectActivation(.tap)
        XCTAssertEqual(settings.triggerKey, .optionD)
    }
}
