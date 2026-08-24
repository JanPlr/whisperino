import AppKit

/// A newly enabled Accessibility grant is not always usable by the process
/// that requested it. Exact-field delivery depends on obtaining a real AX
/// element at take start, so relaunch once after a false -> true transition
/// instead of allowing a half-authorized recording that can only fall back to
/// the notch.
@MainActor
final class AccessibilityPermissionController {
    static let shared = AccessibilityPermissionController()

    private var didRequestThisLaunch = false
    private var grantPollTimer: Timer?

    private init() {}

    func requestIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        if !didRequestThisLaunch {
            didRequestThisLaunch = true
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        guard grantPollTimer == nil else { return }
        grantPollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self.grantPollTimer = nil
                self.relaunchAfterGrant()
            }
        }
    }

    func stop() {
        grantPollTimer?.invalidate()
        grantPollTimer = nil
    }

    private func relaunchAfterGrant() {
        // `open` while this instance is alive may simply focus it. A tiny
        // detached delay lets termination finish before LaunchServices opens
        // the same stable Applications bundle as a fresh process.
        let appPath = Bundle.main.bundleURL.path
            .replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open '\(appPath)'"]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("[whisperino] failed to relaunch after Accessibility grant: \(error.localizedDescription)")
        }
    }
}
