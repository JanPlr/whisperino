import AppKit
import Foundation
import os

private let agentLog = Logger(subsystem: "com.whisperino.app", category: "agent")

/// Current phase of agent execution, displayed in the overlay
enum AgentPhase: Equatable {
    case uploadingAttachments
    case thinking
    case toolCall(name: String)
    case readingDocuments
    case generating

    var displayText: String {
        switch self {
        case .uploadingAttachments:
            return "Uploading attachments\u{2026}"
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
    private let completionsEndpoint = URL(string: "https://api.langdock.com/agent/v1/chat/completions")!
    private let uploadEndpoint = URL(string: "https://api.langdock.com/attachment/v1/upload")!
    private let timeout: TimeInterval = 120

    /// Execute an agent request with streaming.
    /// Calls `onStatusUpdate` when the agent phase changes, returns the final text output.
    func execute(
        agentId: String,
        userMessage: String,
        attachments: [AttachedContext] = [],
        apiKey: String,
        onStatusUpdate: @escaping @Sendable (AgentPhase) -> Void
    ) async throws -> String {
        // Upload image attachments and collect IDs; inline text into the message
        var attachmentIds: [String] = []
        var textContexts: [String] = []

        if !attachments.isEmpty {
            onStatusUpdate(.uploadingAttachments)

            for (i, ctx) in attachments.enumerated() {
                switch ctx.content {
                case .text(let text):
                    textContexts.append("<context index=\"\(i + 1)\">\n\(text)\n</context>")
                case .image(let image):
                    if let id = try? await uploadImage(image, apiKey: apiKey) {
                        attachmentIds.append(id)
                    }
                }
            }
        }

        // Build the user message text — include inline text contexts if any
        let fullMessage: String
        if textContexts.isEmpty {
            fullMessage = userMessage
        } else {
            fullMessage = textContexts.joined(separator: "\n\n")
                + "\n\n<instruction>\n\(userMessage)\n</instruction>"
        }

        var request = URLRequest(url: completionsEndpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messageId = UUID().uuidString
        var message: [String: Any] = [
            "id": messageId,
            "role": "user",
            "parts": [["type": "text", "text": fullMessage]]
        ]
        if !attachmentIds.isEmpty {
            message["metadata"] = ["attachments": attachmentIds]
        }

        let body: [String: Any] = [
            "agentId": agentId,
            "messages": [message],
            "stream": true,
            "maxSteps": 10
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[whisperino] agent request: agentId=\(agentId), message=\(fullMessage.prefix(100))…")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            // Try to read error body
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line; if errorBody.count > 500 { break } }
            print("[whisperino] ❌ agent API HTTP \(statusCode): \(errorBody.prefix(500))")
            throw AgentError.httpError(statusCode)
        }

        var collectedText = ""
        var currentPhase: AgentPhase = .thinking
        onStatusUpdate(currentPhase)

        for try await line in bytes.lines {
            // SSE format: "data: {JSON}" or "data: [DONE]"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continue }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                print("[whisperino] ⚠️ failed to parse SSE: \(trimmed.prefix(300))")
                continue
            }

            switch type {
            case "text-delta":
                if let delta = json["delta"] as? String {
                    collectedText += delta
                    if currentPhase != .generating {
                        currentPhase = .generating
                        onStatusUpdate(currentPhase)
                        print("[whisperino] phase → generating")
                    }
                }

            case "tool-input-start":
                if let toolName = json["toolName"] as? String {
                    let newPhase = AgentPhase.toolCall(name: toolName)
                    if newPhase != currentPhase {
                        currentPhase = newPhase
                        onStatusUpdate(currentPhase)
                        print("[whisperino] phase → tool: \(toolName)")
                    }
                }

            case "tool-output-available":
                // Tool finished, back to thinking for next step
                if currentPhase != .thinking {
                    currentPhase = .thinking
                    onStatusUpdate(currentPhase)
                    print("[whisperino] phase → thinking (tool done)")
                }

            case "finish":
                print("[whisperino] stream finished: \(json["finishReason"] ?? "unknown")")

            default:
                break
            }
        }

        print("[whisperino] agent result: \(collectedText.count) chars collected")
        // Strip Langdock citation markers like 【...】
        let cleaned = collectedText.replacingOccurrences(
            of: "【[^】]*】",
            with: "",
            options: .regularExpression
        )
        let result = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            print("[whisperino] ❌ empty response — no text deltas collected")
            throw AgentError.emptyResponse
        }
        return result
    }

    // MARK: - Attachment upload

    /// Upload an image to the Langdock attachment API. Returns the attachment UUID.
    private func uploadImage(_ image: NSImage, apiKey: String) async throws -> String {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw AgentError.uploadFailed
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: uploadEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"image.png\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(pngData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AgentError.httpError(statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attachmentId = json["attachmentId"] as? String else {
            throw AgentError.uploadFailed
        }

        return attachmentId
    }
}

enum AgentError: LocalizedError {
    case httpError(Int)
    case streamError(String)
    case emptyResponse
    case uploadFailed

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Agent API error (HTTP \(code))"
        case .streamError(let msg): return "Agent stream error: \(msg)"
        case .emptyResponse: return "Agent returned no response"
        case .uploadFailed: return "Failed to upload attachment"
        }
    }
}
