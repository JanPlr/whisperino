import AppKit
import Foundation
import MediaRemoteAdapter
import os

private let mediaPlaybackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Whisperino",
    category: "MediaPlaybackController"
)

private struct MediaPlaybackSnapshot: Equatable {
    let isPlaying: Bool?
    let playbackRate: Double?
    let processIdentifier: pid_t?
    let bundleIdentifier: String?
    let trackIdentifier: String?

    init(trackInfo: TrackInfo) {
        let payload = trackInfo.payload
        isPlaying = payload.isPlaying
        playbackRate = payload.playbackRate
        processIdentifier = payload.PID
        bundleIdentifier = payload.bundleIdentifier

        let parts = [payload.title, payload.artist, payload.album].map {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        trackIdentifier = parts.contains(where: { !$0.isEmpty })
            ? parts.joined(separator: "||")
            : nil
    }

    var isActivelyPlaying: Bool {
        switch (isPlaying, playbackRate) {
        case let (isPlaying?, playbackRate?):
            return isPlaying && playbackRate > 0
        case let (isPlaying?, nil):
            return isPlaying
        case let (nil, playbackRate?):
            return playbackRate > 0
        case (nil, nil):
            return false
        }
    }

    /// MediaRemote can retain stale Now Playing metadata after the player has
    /// quit. Never treat that cached entry as a resumable media session.
    var hasLiveApplication: Bool {
        guard let processIdentifier,
              processIdentifier > 0,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated else {
            return false
        }

        guard let bundleIdentifier else { return true }
        return application.bundleIdentifier == bundleIdentifier
    }

    func matchesMediaContext(of other: MediaPlaybackSnapshot) -> Bool {
        guard let processIdentifier,
              let otherProcessIdentifier = other.processIdentifier,
              processIdentifier == otherProcessIdentifier,
              let bundleIdentifier,
              bundleIdentifier == other.bundleIdentifier,
              let trackIdentifier,
              trackIdentifier == other.trackIdentifier else {
            return false
        }
        return true
    }
}

/// Confirms an active Now Playing session before pausing and records ownership
/// of that pause. End-of-take code can call `resumeIfWePaused` repeatedly; Play
/// is sent only for a pause positively owned by this controller.
final class MediaPlaybackController {
    private let adapter = MediaRemoteRunner()
    private var didPause = false
    private var pausedSnapshot: MediaPlaybackSnapshot?
    private var requestGeneration = 0
    private var resumeGeneration = 0

    private let pauseConfirmationDelay: TimeInterval = 0.15
    private let resumeDelay: TimeInterval = 0.6

    func pauseIfPlaying() {
        cancelPendingResume()
        guard !didPause else { return }

        requestGeneration += 1
        let generation = requestGeneration
        getSnapshot { [weak self] initialSnapshot in
            guard let self,
                  generation == self.requestGeneration,
                  let initialSnapshot,
                  initialSnapshot.hasLiveApplication,
                  initialSnapshot.isActivelyPlaying else {
                return
            }

            DispatchQueue.main.asyncAfter(
                deadline: .now() + self.pauseConfirmationDelay
            ) { [weak self] in
                guard let self,
                      generation == self.requestGeneration,
                      !self.didPause else { return }

                self.getSnapshot { [weak self] confirmedSnapshot in
                    guard let self,
                          generation == self.requestGeneration,
                          !self.didPause,
                          let confirmedSnapshot,
                          confirmedSnapshot.hasLiveApplication,
                          confirmedSnapshot.isActivelyPlaying,
                          confirmedSnapshot.matchesMediaContext(of: initialSnapshot) else {
                        return
                    }

                    // Record ownership before launching the asynchronous helper
                    // command so a stop arriving on the next run-loop turn
                    // cannot miss the pause lease.
                    self.didPause = true
                    self.pausedSnapshot = confirmedSnapshot
                    self.adapter.send("pause")
                    mediaPlaybackLogger.info("Paused confirmed active media session")
                }
            }
        }
    }

    func resumeIfWePaused() {
        // Invalidates either confirmation probe when a very short/no-speech
        // take ends before Whisperino actually pauses anything.
        requestGeneration += 1
        guard didPause else { return }

        cancelPendingResume()
        let generation = resumeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + resumeDelay) { [weak self] in
            guard let self,
                  generation == self.resumeGeneration,
                  self.didPause,
                  let pausedSnapshot = self.pausedSnapshot else { return }

            // Re-read Now Playing immediately before resuming. A bare system
            // Play command with no surviving session can launch Apple Music.
            self.getSnapshot { [weak self] currentSnapshot in
                guard let self,
                      generation == self.resumeGeneration,
                      self.didPause else { return }

                defer { self.clearPauseLease() }
                guard let currentSnapshot,
                      currentSnapshot.hasLiveApplication,
                      currentSnapshot.matchesMediaContext(of: pausedSnapshot),
                      !currentSnapshot.isActivelyPlaying else {
                    mediaPlaybackLogger.info("Skipped resume because the paused media session is no longer current")
                    return
                }

                self.adapter.send("play")
                mediaPlaybackLogger.info("Resumed media session paused by Whisperino")
            }
        }
    }

    private func getSnapshot(
        completion: @escaping (MediaPlaybackSnapshot?) -> Void
    ) {
        adapter.getTrackInfo { trackInfo in
            completion(trackInfo.map(MediaPlaybackSnapshot.init))
        }
    }

    private func cancelPendingResume() {
        resumeGeneration += 1
    }

    private func clearPauseLease() {
        didPause = false
        pausedSnapshot = nil
    }
}

/// Runs the adapter through Apple's entitled `/usr/bin/perl` host. We keep the
/// runner here instead of relying on `Bundle(for:)` because Whisperino is built
/// with SwiftPM as an executable and embeds the adapter as a dylib, not an Xcode
/// framework bundle.
private final class MediaRemoteRunner {
    private let queue = DispatchQueue(
        label: "com.whisperino.media-remote-adapter",
        qos: .userInitiated
    )

    func getTrackInfo(completion: @escaping (TrackInfo?) -> Void) {
        queue.async {
            guard let process = self.makeProcess(command: "get") else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                // Drain while the helper is running: artwork can exceed the
                // pipe buffer even though this caller only needs play state.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                let line: Data
                if let newline = data.firstIndex(of: 0x0A) {
                    line = Data(data[..<newline])
                } else {
                    line = data
                }
                let trackInfo = try? JSONDecoder().decode(TrackInfo.self, from: line)
                DispatchQueue.main.async { completion(trackInfo) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    func send(_ command: String) {
        queue.async {
            guard let process = self.makeProcess(command: command) else { return }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                mediaPlaybackLogger.error(
                    "Media adapter command failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func makeProcess(command: String) -> Process? {
        guard let scriptURL = Self.scriptURL,
              let libraryURL = Self.libraryURL else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, libraryURL.path, command]
        return process
    }

    private static var scriptURL: URL? {
        if let resourceURL = Bundle.main.resourceURL {
            let installed = resourceURL.appendingPathComponent("mediaremote-adapter.pl")
            if FileManager.default.fileExists(atPath: installed.path) { return installed }
        }
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let development = executableDirectory
            .appendingPathComponent("MediaRemoteAdapter_MediaRemoteAdapter.bundle/run.pl")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    private static var libraryURL: URL? {
        if let frameworksURL = Bundle.main.privateFrameworksURL {
            let installed = frameworksURL.appendingPathComponent("libMediaRemoteAdapter.dylib")
            if FileManager.default.fileExists(atPath: installed.path) { return installed }
        }
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let development = executableDirectory.appendingPathComponent("libMediaRemoteAdapter.dylib")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }
}
