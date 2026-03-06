import Foundation

/// Current phase of agent execution, displayed in the overlay
enum AgentPhase: Equatable {
    case thinking
    case toolCall(name: String)
    case readingDocuments
    case generating

    var displayText: String {
        switch self {
        case .thinking:
            return "Thinking\u{2026}"
        case .toolCall(let name):
            switch name {
            case "webSearch":
                return "Searching the web\u{2026}"
            case "dataAnalyst":
                return "Analyzing data\u{2026}"
            case "imageGeneration":
                return "Generating image\u{2026}"
            case "canvas":
                return "Working on canvas\u{2026}"
            default:
                return "Using \(name)\u{2026}"
            }
        case .readingDocuments:
            return "Reading documents\u{2026}"
        case .generating:
            return "Generating response\u{2026}"
        }
    }
}

struct AgentClient {
    private let endpoint = URL(string: "https://api.langdock.com/agent/v1/chat/completions")!
    private let timeout: TimeInterval = 120

    /// Execute an agent request with streaming.
    /// Calls `onStatusUpdate` when the agent phase changes, returns the final text output.
    func execute(
        agentId: String,
        userMessage: String,
        apiKey: String,
        onStatusUpdate: @escaping @Sendable (AgentPhase) -> Void
    ) async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messageId = UUID().uuidString
        let body: [String: Any] = [
            "agentId": agentId,
            "messages": [
                [
                    "id": messageId,
                    "role": "user",
                    "parts": [["type": "text", "text": userMessage]]
                ] as [String: Any]
            ],
            "stream": true,
            "maxSteps": 10
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AgentError.httpError(statusCode)
        }

        var collectedText = ""
        var currentPhase: AgentPhase = .thinking
        onStatusUpdate(currentPhase)

        for try await line in bytes.lines {
            // Vercel AI SDK data stream protocol: "TYPE_CODE:JSON_PAYLOAD"
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let typeCode = String(line[line.startIndex..<colonIndex])
            let payload = String(line[line.index(after: colonIndex)...])

            #if DEBUG
            print("[whisperino] stream \(typeCode): \(payload.prefix(200))")
            #endif

            switch typeCode {
            case "0":
                // Text delta — the final output text
                if let data = payload.data(using: .utf8),
                   let text = try? JSONDecoder().decode(String.self, from: data) {
                    collectedText += text
                    if currentPhase != .generating {
                        currentPhase = .generating
                        onStatusUpdate(currentPhase)
                    }
                }

            case "9":
                // Tool call start — extract tool name
                if let data = payload.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let toolName = json["toolName"] as? String {
                    let newPhase = AgentPhase.toolCall(name: toolName)
                    if newPhase != currentPhase {
                        currentPhase = newPhase
                        onStatusUpdate(currentPhase)
                    }
                }

            case "2":
                // Data message — may contain source references
                if payload.contains("source-document") {
                    let newPhase = AgentPhase.readingDocuments
                    if newPhase != currentPhase {
                        currentPhase = newPhase
                        onStatusUpdate(currentPhase)
                    }
                }

            case "e":
                // Error from stream
                throw AgentError.streamError(payload)

            default:
                // a=tool call delta, b=tool call result, c=step finish, d=finish, f=metadata
                break
            }
        }

        let result = collectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw AgentError.emptyResponse
        }
        return result
    }
}

enum AgentError: LocalizedError {
    case httpError(Int)
    case streamError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Agent API error (HTTP \(code))"
        case .streamError(let msg): return "Agent stream error: \(msg)"
        case .emptyResponse: return "Agent returned no response"
        }
    }
}
