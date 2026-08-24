import AppKit

/// Prevents a downloaded release from onboarding while macOS is running it
/// from Downloads or an App Translocation mount. Accessibility grants created
/// there are easy to confuse with the stable copy the user launches later.
@MainActor
enum ApplicationInstaller {
    private static let expectedBundleIdentifier = "com.whisperino.app"
    private static let installedURL = URL(fileURLWithPath: "/Applications/Whisperino.app")

    /// Returns `true` when launch handling is complete and normal startup must
    /// stop. Developer `swift run` builds are not app bundles and are ignored.
    static func handleUnstableLaunchIfNeeded() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["WHISPERINO_ALLOW_NON_APPLICATIONS"] == "1" {
            return false
        }

        let sourceURL = Bundle.main.bundleURL.standardizedFileURL
        guard sourceURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == expectedBundleIdentifier,
              !sameLocation(sourceURL, installedURL) else {
            return false
        }

        NSApp.activate(ignoringOtherApps: true)

        if FileManager.default.fileExists(atPath: installedURL.path) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Whisperino is already installed"
            alert.informativeText = "This copy is running from an unstable download location. Open the copy in Applications so microphone and Accessibility permissions stay attached to the correct app."
            alert.addButton(withTitle: "Open Installed Copy")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                relaunch(installedURL)
            } else {
                NSApp.terminate(nil)
            }
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install Whisperino before continuing"
        alert.informativeText = "Whisperino must run from Applications before macOS asks for microphone or Accessibility access. This prevents a browser download or temporary App Translocation copy from receiving unusable permissions."
        alert.addButton(withTitle: "Install in Applications")
        alert.addButton(withTitle: "Quit")

        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return true
        }

        do {
            try install(sourceURL)
            relaunch(installedURL)
        } catch {
            showManualInstall(error: error, sourceURL: sourceURL)
        }
        return true
    }

    private static func install(_ sourceURL: URL) throws {
        let fm = FileManager.default
        let stagingURL = installedURL
            .deletingLastPathComponent()
            .appendingPathComponent(".Whisperino.app.installing-\(UUID().uuidString)")

        defer { try? fm.removeItem(at: stagingURL) }
        try fm.copyItem(at: sourceURL, to: stagingURL)

        guard let stagedBundle = Bundle(url: stagingURL),
              stagedBundle.bundleIdentifier == expectedBundleIdentifier else {
            throw InstallError.invalidBundle
        }

        let verifier = Process()
        verifier.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verifier.arguments = ["--verify", "--strict", stagingURL.path]
        try verifier.run()
        verifier.waitUntilExit()
        guard verifier.terminationStatus == 0 else {
            throw InstallError.invalidSignature
        }

        try fm.moveItem(at: stagingURL, to: installedURL)
    }

    private static func showManualInstall(error: Error, sourceURL: URL) {
        NSLog("[whisperino] automatic install failed: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move Whisperino to Applications"
        alert.informativeText = "macOS did not allow Whisperino to install itself. Drag Whisperino.app into Applications, then open it there. No permissions were requested from this temporary copy."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
            NSWorkspace.shared.open(installedURL.deletingLastPathComponent())
        }
        NSApp.terminate(nil)
    }

    private static func relaunch(_ appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appURL.path]
        do {
            try process.run()
        } catch {
            NSLog("[whisperino] failed to open installed app: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }

    private static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path ==
            rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private enum InstallError: LocalizedError {
        case invalidBundle
        case invalidSignature

        var errorDescription: String? {
            switch self {
            case .invalidBundle:
                return "The copied app has an unexpected bundle identifier."
            case .invalidSignature:
                return "The copied app failed code-signature verification."
            }
        }
    }
}
