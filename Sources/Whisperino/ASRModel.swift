import Foundation

/// Speech models Whisperino can download from Hugging Face and run in-process
/// through transcribe.cpp. The default is Parakeet TDT 0.6B v3: lowest WER
/// and the fastest offline Metal path we ship.
enum ASRModelID: String, Codable, CaseIterable, Identifiable {
    case nemotron35
    case whisperTurbo
    case whisperLargeV3
    case parakeetV3

    var id: String { rawValue }
}

enum ASRFamily: String, Equatable {
    case nemotron
    case whisper
    case parakeet
}

struct ASRModelDescriptor: Equatable, Identifiable {
    let id: ASRModelID
    let family: ASRFamily
    let displayName: String
    let shortLabel: String
    let detail: String
    let fileName: String
    let downloadURL: URL
    let expectedBytes: Int64
    let supportsStreaming: Bool
    let supportsAutoLanguage: Bool

    var idValue: String { id.rawValue }
}

enum ASRModelCatalog {
    static let `default`: ASRModelID = .parakeetV3

    static let all: [ASRModelDescriptor] = [
        ASRModelDescriptor(
            id: .parakeetV3,
            family: .parakeet,
            displayName: "Parakeet TDT 0.6B v3",
            shortLabel: "Parakeet",
            detail: "25 European languages, fastest offline. The default — about 705 MB.",
            fileName: "parakeet-tdt-0.6b-v3-Q8_0.gguf",
            downloadURL: URL(string:
                "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf/resolve/main/parakeet-tdt-0.6b-v3-Q8_0.gguf"
            )!,
            expectedBytes: 739_508_576,
            supportsStreaming: false,
            supportsAutoLanguage: false
        ),
        ASRModelDescriptor(
            id: .nemotron35,
            family: .nemotron,
            displayName: "Nemotron 3.5 ASR",
            shortLabel: "Nemotron 3.5",
            detail: "Streaming live transcript, 32 locales. About 716 MB.",
            fileName: "nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf",
            downloadURL: URL(string:
                "https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf/resolve/main/nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf"
            )!,
            expectedBytes: 751_094_240,
            supportsStreaming: true,
            supportsAutoLanguage: true
        ),
        ASRModelDescriptor(
            id: .whisperTurbo,
            family: .whisper,
            displayName: "Whisper large-v3-turbo",
            shortLabel: "Whisper turbo",
            detail: "100 languages, faster Whisper. About 845 MB.",
            fileName: "whisper-large-v3-turbo-Q8_0.gguf",
            downloadURL: URL(string:
                "https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf/resolve/main/whisper-large-v3-turbo-Q8_0.gguf"
            )!,
            expectedBytes: 886_381_760,
            supportsStreaming: false,
            supportsAutoLanguage: true
        ),
        ASRModelDescriptor(
            id: .whisperLargeV3,
            family: .whisper,
            displayName: "Whisper large-v3",
            shortLabel: "Whisper large-v3",
            detail: "100 languages, highest Whisper accuracy. About 1.55 GB.",
            fileName: "whisper-large-v3-Q8_0.gguf",
            downloadURL: URL(string:
                "https://huggingface.co/handy-computer/whisper-large-v3-gguf/resolve/main/whisper-large-v3-Q8_0.gguf"
            )!,
            expectedBytes: 1_668_741_440,
            supportsStreaming: false,
            supportsAutoLanguage: true
        ),
    ]

    static func descriptor(for id: ASRModelID) -> ASRModelDescriptor {
        all.first { $0.id == id } ?? all[0]
    }

    static func modelsDirectory(relativeTo home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".whisperino/models")
    }

    static func localURL(
        for id: ASRModelID,
        relativeTo home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        modelsDirectory(relativeTo: home).appendingPathComponent(descriptor(for: id).fileName)
    }

    /// Map the user's ISO language selection onto the tag the selected family
    /// actually accepts. Empty / several codes mean automatic detection when
    /// the family supports it; Parakeet needs a concrete hint.
    static func recognitionLanguage(
        for id: ASRModelID,
        selectedCodes: [String]
    ) -> (language: String?, prompt: String?) {
        let descriptor = descriptor(for: id)
        let valid = selectedCodes.filter { TranscriptionLanguageCatalog.supportedCodes.contains($0) }

        switch descriptor.family {
        case .whisper:
            let config = TranscriptionLanguageCatalog.recognitionConfiguration(for: valid)
            return (config.language, config.prompt)

        case .nemotron:
            if valid.count == 1, let mapped = nemotronLocale(for: valid[0]) {
                return (mapped, nil)
            }
            // transcribe.cpp autodetect is a NULL language pointer.
            // The string "auto" is not in Nemotron's locale list and is rejected.
            return (nil, nil)

        case .parakeet:
            if valid.count == 1, parakeetLanguages.contains(valid[0]) {
                return (valid[0], nil)
            }
            if let first = valid.first(where: { parakeetLanguages.contains($0) }) {
                return (first, nil)
            }
            return ("en", nil)
        }
    }

    /// Nemotron wants BCP-47 locales (`en-US`), not bare ISO 639-1.
    static func nemotronLocale(for isoCode: String) -> String? {
        nemotronLocales[isoCode]
    }

    static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de",
        "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk",
        "sl", "es", "sv", "ru", "uk",
    ]

    static let nemotronLocales: [String: String] = [
        "ar": "ar-AR",
        "bg": "bg-BG",
        "cs": "cs-CZ",
        "da": "da-DK",
        "de": "de-DE",
        "en": "en-US",
        "es": "es-ES",
        "et": "et-EE",
        "fi": "fi-FI",
        "fr": "fr-FR",
        "hi": "hi-IN",
        "hr": "hr-HR",
        "hu": "hu-HU",
        "it": "it-IT",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "nb": "nb-NO",
        "nl": "nl-NL",
        "nn": "nb-NO",
        "no": "nb-NO",
        "pl": "pl-PL",
        "pt": "pt-BR",
        "ro": "ro-RO",
        "ru": "ru-RU",
        "sk": "sk-SK",
        "sv": "sv-SE",
        "tr": "tr-TR",
        "uk": "uk-UA",
        "vi": "vi-VN",
        "zh": "zh-CN",
    ]
}
