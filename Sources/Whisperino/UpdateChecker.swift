import AppKit

/// In-app updates via GitHub Releases.
///
/// Checks https://api.github.com/repos/JanPlr/whisperino/releases/latest on
/// launch and once a day, compares the tag against the bundle's version, and
/// surfaces the result in the status bar menu. Installing an update downloads
/// the release zip, swaps the app bundle in place, resets the stale
/// Accessibility grant (the ad-hoc CDHash changes every build, so the old
/// grant is dead anyway), and relaunches.
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

        // Fetch the full list (not /releases/latest) and pick the highest
        // version ourselves - GitHub's "latest" is sorted by the tagged
        // commit's date, not by version. .reloadIgnoringLocalCacheData skips
        // URLSession's shared cache, so a stale response from an earlier check
        // can never make "Update now" install an older release.
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=100")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.status = .idle
                    completion?(.failure(error))
                    return
                }
                guard let data,
                      let release = Self.parseLatestRelease(data) else {
                    // No releases yet, or no zip asset - treat as up to date
                    self.status = .idle
                    completion?(.success(nil))
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

    /// Parse the /releases array and return the highest-version installable
    /// release - skipping drafts, pre-releases, and any without a zip asset.
    private static func parseLatestRelease(_ data: Data) -> Release? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return array
            .filter { ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true }
            .compactMap(parseRelease)
            .max { isNewer($1.version, than: $0.version) }
    }

    private static func parseRelease(_ json: [String: Any]) -> Release? {
        guard let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let assetURL = (zip["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, assetURL: assetURL, pageURL: page)
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
