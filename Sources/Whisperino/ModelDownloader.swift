import Foundation
import Combine

/// Hugging Face GGUF downloader. Models live in `~/.whisperino/models/` and
/// are fetched on demand — selecting a model in Settings (or launching with
/// none installed) starts the download.
final class ModelDownloader: NSObject, ObservableObject {
    static let shared = ModelDownloader()

    enum Status: Equatable {
        case idle
        case downloading(id: ASRModelID, received: Int64, expected: Int64)
        case failed(id: ASRModelID, message: String)

        var fraction: Double? {
            guard case .downloading(_, let received, let expected) = self, expected > 0 else {
                return nil
            }
            return min(1, Double(received) / Double(expected))
        }

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .idle
    /// Bumped after every successful install so SwiftUI re-reads `isInstalled`.
    @Published private(set) var installedRevision = 0

    private let home: URL
    private let lock = NSLock()
    private var session: URLSession!
    private var activeTask: URLSessionDownloadTask?
    private var activeID: ASRModelID?
    private var pendingCompletions: [ASRModelID: [() -> Void]] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func isInstalled(_ id: ASRModelID) -> Bool {
        let dest = ASRModelCatalog.localURL(for: id, relativeTo: home)
        guard let size = fileSize(at: dest) else { return false }
        return size >= ASRModelCatalog.descriptor(for: id).expectedBytes / 2
    }

    func localURL(for id: ASRModelID) -> URL {
        ASRModelCatalog.localURL(for: id, relativeTo: home)
    }

    /// Download `id` if it is not already on disk. `onInstalled` runs on a
    /// background queue once the file is ready (or immediately if it already
    /// is). Repeat calls for the same model share one transfer.
    func ensure(_ id: ASRModelID, onInstalled: (() -> Void)? = nil) {
        if isInstalled(id) {
            onInstalled?()
            return
        }
        lock.lock()
        if let onInstalled {
            pendingCompletions[id, default: []].append(onInstalled)
        }
        let alreadyDownloading = activeID == id
        lock.unlock()
        if alreadyDownloading { return }
        startDownload(id)
    }

    func ensureSelected(onInstalled: (() -> Void)? = nil) {
        ensure(SettingsStore.shared.settings.asrModel, onInstalled: onInstalled)
    }

    func cancel() {
        lock.lock()
        activeTask?.cancel()
        activeTask = nil
        activeID = nil
        pendingCompletions.removeAll()
        lock.unlock()
        DispatchQueue.main.async { self.status = .idle }
    }

    private func startDownload(_ id: ASRModelID) {
        let descriptor = ASRModelCatalog.descriptor(for: id)
        let models = ASRModelCatalog.modelsDirectory(relativeTo: home)
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)

        if let free = (try? models.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ))?.volumeAvailableCapacityForImportantUsage,
           free < descriptor.expectedBytes + 500_000_000 {
            let message = "Not enough free disk for \(descriptor.displayName)"
            print("[whisperino] \(message)")
            DispatchQueue.main.async { self.status = .failed(id: id, message: message) }
            return
        }

        lock.lock()
        activeID = id
        lock.unlock()
        DispatchQueue.main.async {
            self.status = .downloading(id: id, received: 0, expected: descriptor.expectedBytes)
        }

        print("[whisperino] downloading \(descriptor.fileName) from Hugging Face…")
        var request = URLRequest(url: descriptor.downloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        lock.lock()
        activeTask = task
        lock.unlock()
        task.priority = URLSessionTask.lowPriority
        task.resume()
    }

    private func finishDownload(tempURL: URL, response: URLResponse?) {
        let id: ASRModelID
        lock.lock()
        guard let current = activeID else {
            lock.unlock()
            return
        }
        id = current
        activeTask = nil
        activeID = nil
        let completions = pendingCompletions.removeValue(forKey: id) ?? []
        lock.unlock()

        let descriptor = ASRModelCatalog.descriptor(for: id)
        let fm = FileManager.default
        let models = ASRModelCatalog.modelsDirectory(relativeTo: home)
        let dest = models.appendingPathComponent(descriptor.fileName)
        let minValid = descriptor.expectedBytes / 2

        guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              let size = fileSize(at: tempURL),
              size >= minValid
        else {
            let message = "Download of \(descriptor.fileName) failed or was truncated"
            print("[whisperino] \(message)")
            DispatchQueue.main.async { self.status = .failed(id: id, message: message) }
            return
        }

        let staging = models.appendingPathComponent(".\(descriptor.fileName).partial")
        do {
            try? fm.removeItem(at: staging)
            try fm.moveItem(at: tempURL, to: staging)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: staging, to: dest)
            print("[whisperino] \(descriptor.fileName) installed (\(size) bytes)")
            DispatchQueue.main.async {
                self.status = .idle
                self.installedRevision += 1
            }
            for completion in completions { completion() }
        } catch {
            try? fm.removeItem(at: staging)
            let message = "Install of \(descriptor.fileName) failed: \(error.localizedDescription)"
            print("[whisperino] \(message)")
            DispatchQueue.main.async { self.status = .failed(id: id, message: message) }
        }
    }

    private func failDownload(_ error: Error) {
        let id: ASRModelID
        lock.lock()
        guard let current = activeID else {
            lock.unlock()
            return
        }
        id = current
        activeTask = nil
        activeID = nil
        pendingCompletions.removeValue(forKey: id)
        lock.unlock()

        if (error as NSError).code == NSURLErrorCancelled {
            DispatchQueue.main.async { self.status = .idle }
            return
        }
        let message = error.localizedDescription
        print("[whisperino] model download failed: \(message)")
        DispatchQueue.main.async { self.status = .failed(id: id, message: message) }
    }

    private func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fm = FileManager.default
        let parked = fm.temporaryDirectory
            .appendingPathComponent("whisperino-model-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: location, to: parked)
        } catch {
            failDownload(error)
            return
        }
        finishDownload(tempURL: parked, response: downloadTask.response)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let id = activeID
        lock.unlock()
        guard let id else { return }
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : ASRModelCatalog.descriptor(for: id).expectedBytes
        DispatchQueue.main.async {
            self.status = .downloading(id: id, received: totalBytesWritten, expected: expected)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { failDownload(error) }
    }
}
