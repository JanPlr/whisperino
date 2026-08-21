import AppKit

/// In-app updates via GitHub Releases.
///
/// Checks GitHub's public Atom releases feed on launch and once a day, compares
/// the highest semantic-version tag against the bundle's version, and surfaces
/// the result in the status bar menu. The feed deliberately avoids GitHub's
/// anonymous REST API quota: many Whisperino installations share one office
/// IP, so its 60-request/hour limit can be exhausted almost immediately.
/// Installing an update downloads the release zip, swaps the app bundle in
/// place, resets the stale Accessibility grant (the ad-hoc CDHash changes
/// every build, so the old grant is dead anyway), and relaunches.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let repo = "JanPlr/whisperino"
    private static let justUpdatedKey = "updaterJustUpdated"

    /// Posted on the main thread whenever `status` changes, so the status-bar
    /// icon can show/hide its "update available" badge without polling.
    static let statusDidChange = Notification.Name("WhisperinoUpdateStatusDidChange")

    struct Release {
        let version: String   // "1.2.0" - tag without the leading "v"
        let assetURL: URL
        let pageURL: URL
    }

    enum Status {
        case idle
        case checking
        case available(Release)
        case downloading
    }

    enum UpdateError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case invalidReleaseFeed

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "GitHub returned an invalid update response."
            case .httpStatus(let status):
                return "GitHub returned HTTP \(status) while checking for updates."
            case .invalidReleaseFeed:
                return "GitHub's release feed did not contain an installable Whisperino version."
            }
        }
    }

    /// Read/written on the main thread only.
    private(set) var status: Status = .idle {
        didSet { NotificationCenter.default.post(name: Self.statusDidChange, object: nil) }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // MARK: - Checking

    /// Silent background check on launch + every 24h + on wake from sleep.
    /// Results only show up as the "Update to vX.Y.Z…" menu item, never as
    /// dialogs. The wake check matters: sleep pauses the daily timer, so a
    /// lid-closed Mac could otherwise carry a days-old result.
    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.check(completion: nil)
        }
        Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.check(completion: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.check(completion: nil)
        }
    }


    /// Menu-initiated check: reports the result via alert when there's
    /// nothing to install (up to date / failed).
    func checkManually() {
        check { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let release?):
                self.offerInstall(release)
            case .success(nil):
                self.showAlert(
                    title: "You're up to date",
                    text: "Whisperino \(Self.currentVersion) is the latest version."
                )
            case .failure(let error):
                self.showAlert(
                    title: "Update check failed",
                    text: error.localizedDescription
                )
            }
        }
    }

    /// completion(.success(nil)) = up to date. Runs on the main thread.
    private func check(completion: ((Result<Release?, Error>) -> Void)?) {
        if case .downloading = status { return }
        if case .checking = status { return }
        status = .checking

        // The unauthenticated GitHub API allows only 60 requests/hour per
        // public IP. In an office, every installation shares that quota. The
        // public Atom feed has no API quota and still exposes every release
        // tag, so parse it and construct our predictably named asset URL.
        // A query nonce plus no-cache headers also prevents a just-published
        // patch from being hidden behind a CDN response.
        let nonce = Int(Date().timeIntervalSince1970)
        let url = URL(string: "https://github.com/\(Self.repo)/releases.atom?whisperino_cache=\(nonce)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.status = .idle
                    completion?(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.status = .idle
                    completion?(.failure(UpdateError.invalidResponse))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    self.status = .idle
                    completion?(.failure(UpdateError.httpStatus(http.statusCode)))
                    return
                }
                guard let data,
                      let release = Self.parseLatestReleaseFeed(data) else {
                    // Never report a malformed/error payload as "up to date".
                    // That was the bug which hid v3.0.1 when the API returned
                    // its JSON rate-limit error instead of release data.
                    self.status = .idle
                    completion?(.failure(UpdateError.invalidReleaseFeed))
                    return
                }
                if Self.isNewer(release.version, than: Self.currentVersion) {
                    self.status = .available(release)
                    completion?(.success(release))
                } else {
                    self.status = .idle
                    completion?(.success(nil))
                }
            }
        }.resume()
    }

    /// Parse release-page links from GitHub's Atom feed and choose the highest
    /// numeric version. Asset names are controlled by our release workflow:
    /// `Whisperino-vX.Y.Z.zip` for tag `vX.Y.Z`.
    static func parseLatestReleaseFeed(_ data: Data) -> Release? {
        guard let feed = String(data: data, encoding: .utf8) else { return nil }
        let escapedRepo = NSRegularExpression.escapedPattern(for: Self.repo)
        let pattern = #"https://github\.com/"# + escapedRepo
            + #"/releases/tag/v([0-9]+(?:\.[0-9]+)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(feed.startIndex..<feed.endIndex, in: feed)

        var versions = Set<String>()
        regex.enumerateMatches(in: feed, range: range) { match, _, _ in
            guard let match,
                  let versionRange = Range(match.range(at: 1), in: feed) else { return }
            versions.insert(String(feed[versionRange]))
        }

        guard let version = versions.max(by: { isNewer($1, than: $0) }),
              let pageURL = URL(string: "https://github.com/\(Self.repo)/releases/tag/v\(version)"),
              let assetURL = URL(string: "https://github.com/\(Self.repo)/releases/download/v\(version)/Whisperino-v\(version).zip")
        else { return nil }
        return Release(version: version, assetURL: assetURL, pageURL: pageURL)
    }

    /// Numeric component-wise compare: "1.10.0" > "1.9.2". Non-numeric
    /// components (e.g. "0.0.0-dev") compare as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    func offerInstall(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Whisperino \(release.version) is available"
        alert.informativeText = """
        You have \(Self.currentVersion). The update downloads, installs, and \
        relaunches automatically.

        Note: macOS will ask you to re-enable Whisperino under Privacy & \
        Security → Accessibility after the update.
        """
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(release)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    func install(_ release: Release) {
        if case .downloading = status { return }
        status = .downloading

        URLSession.shared.downloadTask(with: release.assetURL) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                do {
                    guard let tempURL else {
                        throw error ?? NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download failed."])
                    }
                    try self.swapAndRelaunch(zipAt: tempURL, version: release.version)
                } catch {
                    self.status = .available(release)
                    self.showAlert(title: "Update failed", text: error.localizedDescription)
                }
            }
        }.resume()
    }

    /// Unzip → validate → move current bundle aside → move new one in →
    /// reset the (now stale) Accessibility grant → relaunch.
    private func swapAndRelaunch(zipAt zipURL: URL, version: String) throws {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            throw NSError(domain: "Updater", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Not running from an app bundle - update manually with build.sh."
            ])
        }

        let workDir = fm.temporaryDirectory.appendingPathComponent("whisperino-update-\(version)")
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        try run("/usr/bin/ditto", "-xk", zipURL.path, workDir.path)

        guard let newApp = try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "Updater", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Downloaded archive doesn't contain an app bundle."
            ])
        }

        // Belt and braces: downloads via URLSession aren't quarantined, but a
        // quarantined bundle would show the "damaged app" dialog on relaunch.
        try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", newApp.path)

        let oldApp = workDir.appendingPathComponent("Whisperino-old.app")
        try fm.moveItem(at: appURL, to: oldApp)
        do {
            try fm.moveItem(at: newApp, to: appURL)
        } catch {
            try? fm.moveItem(at: oldApp, to: appURL) // roll back
            throw error
        }

        // The old grant is keyed to the old CDHash and silently broken now.
        // Reset it so the fresh launch shows the grant prompt instead of a
        // confusingly enabled-but-dead toggle.
        try? run("/usr/bin/tccutil", "reset", "Accessibility", "com.whisperino.app")
        UserDefaults.standard.set(true, forKey: Self.justUpdatedKey)

        let script = "sleep 0.7; /usr/bin/open '\(appURL.path)'"
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", script]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    /// First launch after an update: if Accessibility is gone (it always is,
    /// with ad-hoc signing), take the user straight to the right pane on top
    /// of the standard system prompt.
    static func handlePostUpdateLaunch() {
        guard UserDefaults.standard.bool(forKey: justUpdatedKey) else { return }
        UserDefaults.standard.removeObject(forKey: justUpdatedKey)
        if !AXIsProcessTrusted() {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    // MARK: - Helpers

    private func run(_ launchPath: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Updater", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\((launchPath as NSString).lastPathComponent) exited with status \(p.terminationStatus)"
            ])
        }
    }

    private func showAlert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
