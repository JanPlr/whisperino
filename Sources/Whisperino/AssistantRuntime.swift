import AppKit
import EventKit
import Foundation

/// JSON-shaped values are the only data a planner may pass into a tool. The
/// runtime validates them against the registered descriptor before a tool can
/// prepare or execute an invocation.
enum JSONValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

enum ToolEffect: String, Equatable, Sendable {
    case read
    case externalAction
}

enum ToolArgumentType: String, Equatable, Sendable {
    case string
    case integer
    case bool
    case array
    case object
}

struct ToolArgument: Equatable, Sendable {
    let name: String
    let type: ToolArgumentType
    let required: Bool
}

struct ToolDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String
    let effect: ToolEffect
    let privacyLabel: String
    let timeoutSeconds: TimeInterval
    let arguments: [ToolArgument]
}

struct ToolRequest: Equatable, Sendable {
    let toolID: String
    let arguments: [String: JSONValue]
}

/// Prepared invocations are immutable capabilities. Confirmation cards retain
/// this exact value, so approval cannot execute newly planned or edited data.
struct PreparedToolInvocation: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let toolID: String
    let arguments: [String: JSONValue]
    let effect: ToolEffect
    let confirmationTitle: String?
    let confirmationDetail: String?
}

enum AssistantToolResult: Equatable, Sendable {
    case localFiles(query: String, results: [LocalFileResult])
    case actionMessage(symbol: String, title: String, detail: String)
}

enum AssistantRuntimeError: LocalizedError, Equatable {
    case unknownTool(String)
    case missingArgument(tool: String, argument: String)
    case invalidArgument(tool: String, argument: String)
    case unexpectedArgument(tool: String, argument: String)
    case confirmationRequired(String)
    case unsafeFilePath
    case fileUnavailable
    case calendarAccessDenied
    case calendarUnavailable
    case browserOpenFailed

    var errorDescription: String? {
        switch self {
        case .unknownTool(let id):
            return "The assistant tried to use an unavailable tool (\(id))."
        case .missingArgument(let tool, let argument):
            return "\(tool) is missing the required \(argument) value."
        case .invalidArgument(let tool, let argument):
            return "\(tool) received an invalid \(argument) value."
        case .unexpectedArgument(let tool, let argument):
            return "\(tool) does not accept the \(argument) value."
        case .confirmationRequired(let tool):
            return "\(tool) requires confirmation before it can run."
        case .unsafeFilePath:
            return "Whisperino only opens files returned from your home folder."
        case .fileUnavailable:
            return "That file is no longer available."
        case .calendarAccessDenied:
            return "Calendar access was not granted."
        case .calendarUnavailable:
            return "No writable calendar is available."
        case .browserOpenFailed:
            return "The web search could not be opened."
        }
    }
}

protocol AssistantTool {
    var descriptor: ToolDescriptor { get }
    func prepare(arguments: [String: JSONValue], sessionID: UUID) throws -> PreparedToolInvocation
    @MainActor func execute(_ invocation: PreparedToolInvocation) async throws -> AssistantToolResult
}

private enum ToolArgumentValidator {
    static func validate(_ values: [String: JSONValue], for descriptor: ToolDescriptor) throws {
        let fields = Dictionary(uniqueKeysWithValues: descriptor.arguments.map { ($0.name, $0) })

        for key in values.keys where fields[key] == nil {
            throw AssistantRuntimeError.unexpectedArgument(tool: descriptor.displayName, argument: key)
        }

        for field in descriptor.arguments {
            guard let value = values[field.name] else {
                if field.required {
                    throw AssistantRuntimeError.missingArgument(
                        tool: descriptor.displayName,
                        argument: field.name
                    )
                }
                continue
            }

            let matches: Bool
            switch (field.type, value) {
            case (.string, .string), (.integer, .integer), (.bool, .bool),
                 (.array, .array), (.object, .object):
                matches = true
            default:
                matches = false
            }
            if !matches {
                throw AssistantRuntimeError.invalidArgument(
                    tool: descriptor.displayName,
                    argument: field.name
                )
            }
        }
    }
}

/// The registry is the trust boundary between planner output and executable
/// code. Unknown identifiers are rejected; tools validate arguments again
/// during preparation and execution.
final class AssistantToolRegistry {
    private let tools: [String: any AssistantTool]

    init(tools: [any AssistantTool]) {
        var registered: [String: any AssistantTool] = [:]
        for tool in tools {
            precondition(registered[tool.descriptor.id] == nil, "Duplicate assistant tool id")
            registered[tool.descriptor.id] = tool
        }
        self.tools = registered
    }

    var descriptors: [ToolDescriptor] {
        tools.values.map(\.descriptor).sorted { $0.id < $1.id }
    }

    func prepare(_ request: ToolRequest, sessionID: UUID) throws -> PreparedToolInvocation {
        guard let tool = tools[request.toolID] else {
            throw AssistantRuntimeError.unknownTool(request.toolID)
        }
        try ToolArgumentValidator.validate(request.arguments, for: tool.descriptor)
        return try tool.prepare(arguments: request.arguments, sessionID: sessionID)
    }

    @MainActor
    func execute(_ invocation: PreparedToolInvocation, confirmed: Bool) async throws -> AssistantToolResult {
        try validateExecution(invocation, confirmed: confirmed)
        guard let tool = tools[invocation.toolID] else {
            throw AssistantRuntimeError.unknownTool(invocation.toolID)
        }

        return try await tool.execute(invocation)
    }

    /// Synchronous preflight used by the host before it enters an async tool.
    /// Kept separate so confirmation policy can be tested without performing
    /// an OS action.
    func validateExecution(_ invocation: PreparedToolInvocation, confirmed: Bool) throws {
        guard let tool = tools[invocation.toolID] else {
            throw AssistantRuntimeError.unknownTool(invocation.toolID)
        }
        try ToolArgumentValidator.validate(invocation.arguments, for: tool.descriptor)
        guard invocation.effect == tool.descriptor.effect else {
            throw AssistantRuntimeError.invalidArgument(
                tool: tool.descriptor.displayName,
                argument: "effect"
            )
        }
        if tool.descriptor.effect == .externalAction, !confirmed {
            throw AssistantRuntimeError.confirmationRequired(tool.descriptor.displayName)
        }
    }
}

struct LocalFinderAssistantTool: AssistantTool {
    static let id = "finder.search"

    let descriptor = ToolDescriptor(
        id: id,
        displayName: "Finder search",
        effect: .read,
        privacyLabel: "On-device filenames",
        timeoutSeconds: 10,
        arguments: [
            ToolArgument(name: "query", type: .string, required: true),
            ToolArgument(name: "limit", type: .integer, required: false),
        ]
    )

    func prepare(arguments: [String: JSONValue], sessionID: UUID) throws -> PreparedToolInvocation {
        guard let query = arguments["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            throw AssistantRuntimeError.invalidArgument(tool: descriptor.displayName, argument: "query")
        }
        let limit = arguments["limit"]?.integerValue ?? 5
        guard (1...10).contains(limit) else {
            throw AssistantRuntimeError.invalidArgument(tool: descriptor.displayName, argument: "limit")
        }
        return PreparedToolInvocation(
            id: UUID(),
            sessionID: sessionID,
            toolID: descriptor.id,
            arguments: ["query": .string(query), "limit": .integer(limit)],
            effect: descriptor.effect,
            confirmationTitle: nil,
            confirmationDetail: nil
        )
    }

    @MainActor
    func execute(_ invocation: PreparedToolInvocation) async throws -> AssistantToolResult {
        guard let query = invocation.arguments["query"]?.stringValue,
              let limit = invocation.arguments["limit"]?.integerValue else {
            throw AssistantRuntimeError.invalidArgument(tool: descriptor.displayName, argument: "arguments")
        }
        let results = try await LocalFinderTool.search(query: query, limit: limit)
        try Task.checkCancellation()
        return .localFiles(query: query, results: results)
    }
}

struct OpenLocalFileAssistantTool: AssistantTool {
    static let id = "finder.open"

    let descriptor = ToolDescriptor(
        id: id,
        displayName: "Open file",
        effect: .externalAction,
        privacyLabel: "Local file access",
        timeoutSeconds: 5,
        arguments: [
            ToolArgument(name: "path", type: .string, required: true),
            ToolArgument(name: "name", type: .string, required: true),
            ToolArgument(name: "detail", type: .string, required: true),
            ToolArgument(name: "symbol", type: .string, required: true),
        ]
    )

    func prepare(arguments: [String: JSONValue], sessionID: UUID) throws -> PreparedToolInvocation {
        guard let rawPath = arguments["path"]?.stringValue,
              let name = arguments["name"]?.stringValue,
              !name.isEmpty else {
            throw AssistantRuntimeError.invalidArgument(tool: descriptor.displayName, argument: "path")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        let url = URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard url.path == home || url.path.hasPrefix(home + "/") else {
            throw AssistantRuntimeError.unsafeFilePath
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AssistantRuntimeError.fileUnavailable
        }

        var safeArguments = arguments
        safeArguments["path"] = .string(url.path)
        return PreparedToolInvocation(
            id: UUID(),
            sessionID: sessionID,
            toolID: descriptor.id,
            arguments: safeArguments,
            effect: descriptor.effect,
            confirmationTitle: "Open \(name)?",
            confirmationDetail: arguments["detail"]?.stringValue
        )
    }

    @MainActor
    func execute(_ invocation: PreparedToolInvocation) async throws -> AssistantToolResult {
        guard let path = invocation.arguments["path"]?.stringValue,
              let name = invocation.arguments["name"]?.stringValue,
              let detail = invocation.arguments["detail"]?.stringValue else {
            throw AssistantRuntimeError.invalidArgument(tool: descriptor.displayName, argument: "arguments")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw AssistantRuntimeError.fileUnavailable
        }
        let opened = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return .actionMessage(
            symbol: opened ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            title: opened ? "Opened \(name)" : "Couldn’t open \(name)",
            detail: opened ? detail : "The file may have moved or its app may be unavailable."
        )
    }
}

struct CreateCalendarEventAssistantTool: AssistantTool {
    static let id = "calendar.create"

    let descriptor = ToolDescriptor(
        id: id,
        displayName: "Save calendar event",
        effect: .externalAction,
        privacyLabel: "Calendar write",
        timeoutSeconds: 15,
        arguments: [
            ToolArgument(name: "title", type: .string, required: true),
            ToolArgument(name: "start", type: .integer, required: true),
            ToolArgument(name: "end", type: .integer, required: true),
            ToolArgument(name: "attendees", type: .array, required: false),
            ToolArgument(name: "location", type: .string, required: false),
        ]
    )

    func prepare(arguments: [String: JSONValue], sessionID: UUID) throws -> PreparedToolInvocation {
        guard let title = arguments["title"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let startSeconds = arguments["start"]?.integerValue,
              let endSeconds = arguments["end"]?.integerValue,
              endSeconds > startSeconds,
              endSeconds - startSeconds <= 86_400 else {
            throw AssistantRuntimeError.invalidArgument(
                tool: descriptor.displayName,
                argument: "event"
            )
        }

        let attendees = try Self.attendees(from: arguments["attendees"])
        let location = arguments["location"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var safeArguments: [String: JSONValue] = [
            "title": .string(title),
            "start": .integer(startSeconds),
            "end": .integer(endSeconds),
            "attendees": .array(attendees.map(JSONValue.string)),
        ]
        if let location, !location.isEmpty { safeArguments["location"] = .string(location) }

        let draft = Self.draft(from: safeArguments)!
        return PreparedToolInvocation(
            id: UUID(),
            sessionID: sessionID,
            toolID: descriptor.id,
            arguments: safeArguments,
            effect: descriptor.effect,
            confirmationTitle: "Save \(title)?",
            confirmationDetail: Self.dateIntervalLabel(for: draft)
        )
    }

    @MainActor
    func execute(_ invocation: PreparedToolInvocation) async throws -> AssistantToolResult {
        guard let draft = Self.draft(from: invocation.arguments) else {
            throw AssistantRuntimeError.invalidArgument(
                tool: descriptor.displayName,
                argument: "event"
            )
        }

        let eventStore = EKEventStore()
        let granted = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Bool, Error>) in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
        guard granted else { throw AssistantRuntimeError.calendarAccessDenied }
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw AssistantRuntimeError.calendarUnavailable
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.calendar = calendar
        event.location = draft.location
        if !draft.attendeeEmails.isEmpty {
            // EventKit does not expose a supported API for adding invitees.
            // Preserve the spoken addresses visibly without pretending an
            // invitation was sent.
            event.notes = "Invitees: " + draft.attendeeEmails.joined(separator: ", ")
        }
        try eventStore.save(event, span: .thisEvent, commit: true)

        return .actionMessage(
            symbol: "calendar.badge.checkmark",
            title: "Saved \(draft.title)",
            detail: Self.dateIntervalLabel(for: draft)
        )
    }

    static func draft(from arguments: [String: JSONValue]) -> CalendarEventDraft? {
        guard let title = arguments["title"]?.stringValue,
              let startSeconds = arguments["start"]?.integerValue,
              let endSeconds = arguments["end"]?.integerValue,
              let attendees = try? attendees(from: arguments["attendees"]) else { return nil }
        return CalendarEventDraft(
            title: title,
            start: Date(timeIntervalSince1970: TimeInterval(startSeconds)),
            end: Date(timeIntervalSince1970: TimeInterval(endSeconds)),
            attendeeEmails: attendees,
            location: arguments["location"]?.stringValue
        )
    }

    private static func attendees(from value: JSONValue?) throws -> [String] {
        guard let value else { return [] }
        guard let values = value.arrayValue else {
            throw AssistantRuntimeError.invalidArgument(
                tool: "Save calendar event",
                argument: "attendees"
            )
        }
        return try values.map { value in
            guard let email = value.stringValue,
                  email.contains("@"), !email.contains(" ") else {
                throw AssistantRuntimeError.invalidArgument(
                    tool: "Save calendar event",
                    argument: "attendees"
                )
            }
            return email
        }
    }

    private static func dateIntervalLabel(for draft: CalendarEventDraft) -> String {
        let day = DateFormatter.localizedString(from: draft.start, dateStyle: .medium, timeStyle: .none)
        let start = DateFormatter.localizedString(from: draft.start, dateStyle: .none, timeStyle: .short)
        let end = DateFormatter.localizedString(from: draft.end, dateStyle: .none, timeStyle: .short)
        return "\(day) · \(start) - \(end)"
    }
}

struct WebSearchAssistantTool: AssistantTool {
    static let id = "browser.search"

    let descriptor = ToolDescriptor(
        id: id,
        displayName: "Open web search",
        effect: .externalAction,
        privacyLabel: "Opens the default browser",
        timeoutSeconds: 5,
        arguments: [ToolArgument(name: "query", type: .string, required: true)]
    )

    func prepare(arguments: [String: JSONValue], sessionID: UUID) throws -> PreparedToolInvocation {
        guard let query = arguments["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty, query.count <= 500 else {
            throw AssistantRuntimeError.invalidArgument(tool: descriptor.displayName, argument: "query")
        }
        return PreparedToolInvocation(
            id: UUID(),
            sessionID: sessionID,
            toolID: descriptor.id,
            arguments: ["query": .string(query)],
            effect: descriptor.effect,
            confirmationTitle: "Search the web?",
            confirmationDetail: query
        )
    }

    @MainActor
    func execute(_ invocation: PreparedToolInvocation) async throws -> AssistantToolResult {
        guard let query = invocation.arguments["query"]?.stringValue,
              var components = URLComponents(string: "https://www.google.com/search") else {
            throw AssistantRuntimeError.invalidArgument(tool: descriptor.displayName, argument: "query")
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            throw AssistantRuntimeError.browserOpenFailed
        }
        return .actionMessage(
            symbol: "safari.fill",
            title: "Opened web search",
            detail: query
        )
    }
}

struct AssistantPlan: Equatable, Sendable {
    let summary: String
    let requests: [ToolRequest]
}

/// A conservative local planner. Requests it cannot identify stay on the
/// existing remote answer path. Even future model planners must emit this same
/// ToolRequest shape and pass through AssistantToolRegistry.
struct AssistantPlanner {
    private let registeredToolIDs: Set<String>

    init(descriptors: [ToolDescriptor]) {
        registeredToolIDs = Set(descriptors.map(\.id))
    }

    func plan(_ transcription: String) -> AssistantPlan? {
        if registeredToolIDs.contains(LocalFinderAssistantTool.id),
           let query = LocalFinderTool.query(from: transcription) {
            return AssistantPlan(
                summary: "Searching this Mac",
                requests: [ToolRequest(
                    toolID: LocalFinderAssistantTool.id,
                    arguments: ["query": .string(query), "limit": .integer(8)]
                )]
            )
        }

        if registeredToolIDs.contains(CreateCalendarEventAssistantTool.id),
           let draft = LocalCalendarDraftParser.parse(transcription) {
            return AssistantPlan(
                summary: "Preparing calendar event",
                requests: [ToolRequest(
                    toolID: CreateCalendarEventAssistantTool.id,
                    arguments: Self.calendarArguments(draft)
                )]
            )
        }

        if registeredToolIDs.contains(WebSearchAssistantTool.id),
           let query = LocalWebSearchParser.query(from: transcription) {
            return AssistantPlan(
                summary: "Preparing web search",
                requests: [ToolRequest(
                    toolID: WebSearchAssistantTool.id,
                    arguments: ["query": .string(query)]
                )]
            )
        }
        return nil
    }

    func shouldAttemptModelPlanning(_ transcription: String) -> Bool {
        let lower = transcription.lowercased()
        return ["find", "search", "open", "create", "add", "schedule", "book"]
            .contains(where: lower.contains)
    }

    private static func calendarArguments(_ draft: CalendarEventDraft) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "title": .string(draft.title),
            "start": .integer(Int(draft.start.timeIntervalSince1970)),
            "end": .integer(Int(draft.end.timeIntervalSince1970)),
            "attendees": .array(draft.attendeeEmails.map(JSONValue.string)),
        ]
        if let location = draft.location { arguments["location"] = .string(location) }
        return arguments
    }
}

private enum LocalCalendarDraftParser {
    static func parse(_ transcription: String) -> CalendarEventDraft? {
        let lower = transcription.lowercased()
        let hasCalendarIntent = ["calendar", "event", "meeting", "appointment"]
            .contains(where: lower.contains)
        let hasCreateIntent = ["create", "add", "schedule", "book", "put"]
            .contains(where: lower.contains)
        guard hasCalendarIntent, hasCreateIntent,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(
                in: transcription,
                options: [],
                range: NSRange(transcription.startIndex..., in: transcription)
              ),
              let start = match.date,
              let matchRange = Range(match.range, in: transcription) else { return nil }

        let end = match.duration > 0 ? start.addingTimeInterval(match.duration) : start.addingTimeInterval(3600)
        let emails = emailAddresses(in: transcription)

        var title = transcription
        title.removeSubrange(matchRange)
        for email in emails { title = title.replacingOccurrences(of: email, with: "") }
        let cleanupPatterns = [
            #"(?i)^\s*(please\s+)?(can|could|would)\s+you\s+"#,
            #"(?i)^\s*(please\s+)?(create|add|schedule|book|put)\s+"#,
            #"(?i)\b(a|an|the|new)\s+(calendar\s+)?(event|meeting|appointment)\b"#,
            #"(?i)\b(on|to|in)\s+(my\s+)?calendar\b"#,
            #"(?i)\b(with|invite|inviting)\s*$"#,
            #"\s+"#,
        ]
        for pattern in cleanupPatterns {
            title = title.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !title.isEmpty else { return nil }

        return CalendarEventDraft(
            title: title.prefix(1).uppercased() + title.dropFirst(),
            start: start,
            end: end,
            attendeeEmails: emails,
            location: nil
        )
    }

    private static func emailAddresses(in text: String) -> [String] {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

private enum LocalWebSearchParser {
    static func query(from transcription: String) -> String? {
        let lower = transcription.lowercased()
        guard ["search the web", "google", "linkedin", "find online", "look up online"]
            .contains(where: lower.contains) else { return nil }

        var query = transcription
        let patterns = [
            #"(?i)^\s*(please\s+)?(can|could|would)\s+you\s+"#,
            #"(?i)^\s*(please\s+)?(find|search|google|look up)\s+"#,
            #"(?i)\b(and\s+)?open\b"#,
            #"(?i)\b(on|from)\s+the\s+web\b"#,
            #"[?!.]+$"#,
            #"\s+"#,
        ]
        for pattern in patterns {
            query = query.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }
}

enum AssistantSessionPhase: Equatable, Sendable {
    case listening
    case transcribing
    case planning
    case executing(toolID: String)
    case awaitingConfirmation(PreparedToolInvocation)
    case presenting
    case failed(String)
    case cancelled
}

struct AssistantSessionState: Identifiable, Equatable, Sendable {
    let id: UUID
    var phase: AssistantSessionPhase
    var transcript: String?
    var trace: [String]

    init(id: UUID = UUID(), phase: AssistantSessionPhase) {
        self.id = id
        self.phase = phase
        self.transcript = nil
        self.trace = []
    }

    mutating func transition(to phase: AssistantSessionPhase, label: String) {
        self.phase = phase
        trace.append(label)
    }
}
