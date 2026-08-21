import AppKit
import SwiftUI

/// An environment-gated, deterministic visual harness for the notch. This is
/// intentionally part of the executable so QA renders the exact production
/// OverlayView rather than a hand-built mock that can drift from it.
enum NotchVisualQAPreview {
    private static var window: NSWindow?
    private static var audioDriver: NotchAudioQADriver?

    @MainActor
    static func present(mode: String) {
        let previewState = AppState()
        previewState.overlayHasPhysicalNotch = true
        previewState.overlayUsesTopEdgeSurface = true
        previewState.overlayNotchInset = 32
        previewState.audioSamples = [0.12, 0.35, 0.22, 0.08] + Array(repeating: 0, count: 9)

        switch mode {
        case "calendar":
            let start = Date().addingTimeInterval(86_400)
            previewState.state = .result(text: "Review calendar event")
            previewState.assistantCard = .calendarDraft(
                CalendarEventDraft(
                    title: "Design review with David",
                    start: start,
                    end: start.addingTimeInterval(1_800),
                    attendeeEmails: ["david@company.com"],
                    location: "Google Meet"
                )
            )
        case "finder":
            previewState.state = .result(text: "Found 3 files")
            previewState.assistantCard = .fileResults(
                query: "2025 Tax Returns",
                results: [
                    LocalFileResult(
                        name: "2025 California Tax Return.pdf",
                        path: "/tmp/california.pdf",
                        detail: "PDF · ~/Documents/2025 Tax Returns",
                        symbolName: "doc.richtext.fill",
                        sizeLabel: "4.9 KB",
                        modifiedLabel: "8:02 PM"
                    ),
                    LocalFileResult(
                        name: "2025 Form 1040 Tax Return.pdf",
                        path: "/tmp/1040.pdf",
                        detail: "PDF · ~/Documents/2025 Tax Returns",
                        symbolName: "doc.richtext.fill",
                        sizeLabel: "6.1 KB",
                        modifiedLabel: "8:02 PM"
                    ),
                    LocalFileResult(
                        name: "2025 Form 1099 Income.pdf",
                        path: "/tmp/1099.pdf",
                        detail: "PDF · ~/Documents/2025 Tax Returns",
                        symbolName: "doc.richtext.fill",
                        sizeLabel: "3.9 KB",
                        modifiedLabel: "8:02 PM"
                    ),
                ]
            )
        case "processing":
            previewState.state = .transcribing
            previewState.liveTranscript = "What’s actually being transcribed right now."
        case "processing-compact":
            previewState.state = .transcribing
        case "error":
            previewState.state = .error(
                message: "Mic error: The microphone did not respond. Reconnect it or choose another input"
            )
        case "fallback", "fallback-light":
            previewState.state = .result(text: "Is this not transcribing?")
            previewState.fallbackResult = "Is this not transcribing?"
        case "hover":
            break
        case "external-idle", "external-hover":
            previewState.overlayHasPhysicalNotch = false
            previewState.overlayUsesTopEdgeSurface = true
            previewState.overlayNotchInset = 28
            previewState.overlayPhysicalNotchWidth = 188
        case "external-listening":
            previewState.overlayHasPhysicalNotch = false
            previewState.overlayUsesTopEdgeSurface = true
            previewState.overlayNotchInset = 28
            previewState.overlayPhysicalNotchWidth = 160
            previewState.state = .recording
        case "listening-silent":
            previewState.state = .recording
            previewState.audioSamples = Array(repeating: 0, count: AppState.waveformBarCount)
        case "listening-quiet":
            previewState.state = .recording
            previewState.audioSamples = [
                0.018, 0.024, 0.031, 0.022, 0.015,
                0.012, 0.019, 0.027, 0.021, 0.014,
                0.010, 0.016, 0.023,
            ]
        case "picker", "picker-wide":
            previewState.state = .recording
            if mode == "picker-wide" {
                // Exercises the narrow side wings found on wider MacBook
                // camera housings—the geometry that exposed header drift.
                previewState.overlayPhysicalNotchWidth = 272
            }
            previewState.inputDevices = [
                AudioInputDevice(id: 1, name: "MacBook Pro Microphone", uid: "qa-built-in"),
                AudioInputDevice(id: 2, name: "Studio Display Microphone", uid: "qa-display"),
                AudioInputDevice(id: 3, name: "AirPods Pro", uid: "qa-airpods"),
            ]
            previewState.selectedInputDevice = previewState.inputDevices[0]
            previewState.showingInputPicker = true
        default:
            previewState.state = .recording
            let driver = NotchAudioQADriver(state: previewState)
            driver.start()
            audioDriver = driver
        }

        let background = LinearGradient(
            colors: mode == "fallback-light"
                ? [Color.white, Color(red: 0.91, green: 0.92, blue: 0.94)]
                : [
                    Color(red: 0.12, green: 0.52, blue: 0.76),
                    Color(red: 0.02, green: 0.20, blue: 0.55),
                  ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let previewContent: AnyView
        if mode == "hover" {
            previewContent = AnyView(
                NotchHoverVisualQARepresentable()
                    .frame(width: 246, height: 48)
            )
        } else if mode == "external-idle" || mode == "external-hover" {
            previewContent = AnyView(
                ExternalTopEdgeVisualQARepresentable(hovered: mode == "external-hover")
                    .frame(width: 244, height: 36)
            )
        } else {
            previewContent = AnyView(OverlayView(appState: previewState))
        }

        let root = ZStack(alignment: .top) {
            background.ignoresSafeArea()
            previewContent
        }
        .frame(width: 700, height: 460, alignment: .top)

        let previewWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        previewWindow.title = "Whisperino Notch Visual QA — \(mode)"
        previewWindow.contentView = NSHostingView(rootView: root)
        previewWindow.center()
        previewWindow.makeKeyAndOrderFront(nil)
        window = previewWindow
    }
}

private struct NotchHoverVisualQARepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        makeNotchHoverVisualQAView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct ExternalTopEdgeVisualQARepresentable: NSViewRepresentable {
    let hovered: Bool

    func makeNSView(context: Context) -> NSView {
        makeExternalTopEdgeVisualQAView(hovered: hovered)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Selector-based timer avoids introducing concurrency warnings into the
/// production target while still exercising the real spring animation in QA.
private final class NotchAudioQADriver: NSObject {
    private weak var state: AppState?
    private var timer: Timer?
    private var phase: Double = 0

    init(state: AppState) {
        self.state = state
    }

    func start() {
        timer = Timer.scheduledTimer(
            timeInterval: 1.0 / 22.0,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func tick() {
        phase += 0.23
        state?.audioSamples = (0..<AppState.waveformBarCount).map { index in
            let carrier = (sin(phase - Double(index) * 0.42) + 1) / 2
            let envelope = (sin(phase * 0.41) + 1) / 2
            return Float(0.04 + carrier * (0.16 + envelope * 0.50))
        }
    }
}
