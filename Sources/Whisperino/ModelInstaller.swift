import Foundation

/// One-shot background download of the default transcription model.
///
/// v2 switched the default model from medium to large-v3-turbo. Fresh
/// setup.sh runs download it, but the in-app updater only swaps the app
/// bundle - an updated install still has just ggml-medium.bin on disk.
/// This fetches the new default in the background on launch so updated
/// installs converge on it without re-running setup.sh; transcription
/// keeps using medium until the new model is fully in place.
enum ModelInstaller {
    static let defaultModel = "ggml-large-v3-turbo.bin"

    private static let modelURL = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!

    /// Reject error pages and truncated downloads - the real model is ~1.6GB.
    private static let minValidSize: Int64 = 1_000_000_000

    /// Download the default model if it isn't on disk yet, then call
    /// `onInstalled` (from a background thread) once it is ready to use.
    /// Call once at launch - repeat calls would race a second download.
    /// Failures are logged and left for the next launch to retry.
    static func ensureDefaultModel(onInstalled: @escaping () -> Void) {
        let fm = FileManager.default
        let models = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".whisperino/models")
        let dest = models.appendingPathComponent(defaultModel)
        guard !fm.fileExists(atPath: dest.path) else { return }
        try? fm.createDirectory(at: models, withIntermediateDirectories: true)

        // Don't start a 1.6GB download the volume can't hold.
        if let free = (try? models.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ))?.volumeAvailableCapacityForImportantUsage,
           free < 3_000_000_000 {
            print("[whisperino] skipping \(defaultModel) download - only \(free / 1_000_000_000)GB free")
            return
        }

        print("[whisperino] downloading \(defaultModel) (~1.6GB) in the background...")
        let task = URLSession.shared.downloadTask(with: modelURL) { temp, response, error in
            guard error == nil,
                  let temp,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let size = (try? fm.attributesOfItem(atPath: temp.path)[.size]) as? Int64,
                  size >= minValidSize
            else {
                print("[whisperino] \(defaultModel) download failed (\(error?.localizedDescription ?? "bad response")) - retrying next launch")
                return
            }
            // Stage next to the destination, then rename. The temp file
            // lives on the system volume and a cross-volume move is
            // copy+delete - a crash mid-copy must never leave a truncated
            // file under the real model name, or every transcription
            // after it would fail to load the model.
            let staging = models.appendingPathComponent(".\(defaultModel).partial")
            do {
                try? fm.removeItem(at: staging)
                try fm.moveItem(at: temp, to: staging)
                try fm.moveItem(at: staging, to: dest)
                print("[whisperino] \(defaultModel) installed")
                onInstalled()
            } catch {
                try? fm.removeItem(at: staging)
                print("[whisperino] \(defaultModel) install failed: \(error.localizedDescription)")
            }
        }
        // Yield to dictation traffic - this can take a while and nobody is
        // waiting on it.
        task.priority = URLSessionTask.lowPriority
        task.resume()
    }
}
