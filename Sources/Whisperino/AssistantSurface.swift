import AppKit
import Foundation

/// A local file surfaced by the assistant. Only display-safe metadata is kept
/// in the UI state; the file itself never leaves the Mac.
struct LocalFileResult: Identifiable, Equatable, Sendable {
    var id: String { path }

    let name: String
    let path: String
    let detail: String
    let symbolName: String
    var sizeLabel: String? = nil
    var modifiedLabel: String? = nil

    var url: URL { URL(fileURLWithPath: path) }
}

struct CalendarEventDraft: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let attendeeEmails: [String]
    let location: String?
}

struct WebSearchDraft: Equatable, Sendable {
    let query: String
}

/// The compact, native card shown below the notch after a tool call. Keeping
/// this as app-owned state (rather than model-authored SwiftUI) gives every
/// integration the same trusted confirmation boundary.
enum AssistantCard: Equatable {
    case fileResults(query: String, results: [LocalFileResult])
    case confirmOpen(LocalFileResult)
    case calendarDraft(CalendarEventDraft)
    case webSearch(WebSearchDraft)
    case message(symbol: String, title: String, detail: String)
}

enum LocalFinderTool {
    private static let commandPrefixes = [
        "search for ", "search my mac for ", "find me ", "find ",
        "locate ", "show me ", "look for ",
    ]

    private static let fileSignals = [
        " file", " folder", " document", " pdf", " spreadsheet",
        " presentation", " download", " desktop", " in finder",
        " on my mac", ".pdf", ".doc", ".docx", ".xls", ".xlsx",
        ".ppt", ".pptx", ".txt", ".md",
    ]

    /// Conservative local routing. A generic request such as "find out why"
    /// stays with the conversational agent; a request that explicitly names a
    /// file concept is handled locally.
    static func query(from transcription: String) -> String? {
        let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard commandPrefixes.contains(where: lower.hasPrefix),
              fileSignals.contains(where: lower.contains) else { return nil }

        var query = trimmed
        if let prefix = commandPrefixes.first(where: lower.hasPrefix) {
            query.removeFirst(prefix.count)
        }

        let removablePhrases = [
            "on my mac", "in finder", "from finder", "please",
            "the file called", "a file called", "the folder called",
            "a folder called",
        ]
        for phrase in removablePhrases {
            query = query.replacingOccurrences(
                of: phrase,
                with: "",
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return query.isEmpty ? nil : query
    }

    /// Run Spotlight out-of-process so a slow metadata index cannot block the
    /// hotkey/main-actor path. Arguments are passed directly to `Process` (no
    /// shell), so spoken text cannot be interpreted as a command.
    static func search(query: String, limit: Int = 6) async throws -> [LocalFileResult] {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = [
                "-onlyin", FileManager.default.homeDirectoryForCurrentUser.path,
                "-interpret", query,
            ]
            process.standardOutput = output
            process.standardError = errors

            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(
                    domain: "Whisperino.LocalFinderTool",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false
                        ? message!
                        : "Spotlight search failed"]
                )
            }

            let paths = String(data: data, encoding: .utf8)?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init) ?? []

            var seen = Set<String>()
            return paths.compactMap { path -> LocalFileResult? in
                guard seen.insert(path).inserted,
                      !path.contains("/.Trash/"),
                      !path.contains("/Library/Caches/") else { return nil }

                let url = URL(fileURLWithPath: path)
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
                ])
                let isDirectory = values?.isDirectory == true
                let extensionName = url.pathExtension.uppercased()
                let kind = isDirectory ? "Folder" : (extensionName.isEmpty ? "File" : extensionName)
                let parent = url.deletingLastPathComponent().path
                    .replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path,
                        with: "~"
                    )
                return LocalFileResult(
                    name: url.lastPathComponent,
                    path: path,
                    detail: "\(kind) · \(parent)",
                    symbolName: isDirectory ? "folder.fill" : symbol(for: extensionName),
                    sizeLabel: values?.fileSize.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                    },
                    modifiedLabel: values?.contentModificationDate.map {
                        DateFormatter.localizedString(
                            from: $0,
                            dateStyle: .short,
                            timeStyle: .short
                        )
                    }
                )
            }
            .prefix(limit)
            .map { $0 }
        }.value
    }

    private static func symbol(for extensionName: String) -> String {
        switch extensionName {
        case "PDF": return "doc.richtext.fill"
        case "PNG", "JPG", "JPEG", "HEIC", "GIF": return "photo.fill"
        case "MOV", "MP4", "M4V": return "film.fill"
        case "MP3", "M4A", "WAV", "AIFF": return "waveform"
        case "XLS", "XLSX", "CSV": return "tablecells.fill"
        case "PPT", "PPTX", "KEY": return "rectangle.on.rectangle.angled"
        default: return "doc.fill"
        }
    }
}
