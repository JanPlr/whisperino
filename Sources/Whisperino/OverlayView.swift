import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store = SettingsStore.shared

    /// Team Rafterino easter egg - retints the pill (never reshapes it).
    private var rafterino: Bool { store.settings.rafterinoModeEnabled }

    private var isDismissing: Bool {
        if case .dismissing = appState.state { return true }
        return false
    }

    private var isCancelled: Bool {
        if case .cancelled = appState.state { return true }
        return false
    }

    /// True from "recording stopped" until the pill is gone - the span
    /// where the unified pill shows the typing flow instead of the
    /// waveform.
    private var isProcessingState: Bool {
        switch appState.state {
        case .transcribing, .refining, .result, .dismissing: return true
        default: return false
        }
    }

    /// A deliberately small set of visual phases for the physical-notch shell.
    /// The shell itself never gets replaced while a take is active; only this
    /// phase changes, which lets SwiftUI interpolate one top-anchored shape
    /// instead of crossfading unrelated pills and cards.
    private var notchPresentation: String {
        if appState.assistantCard != nil { return "assistant" }
        if appState.fallbackResult != nil { return "fallback" }
        if appState.showingInputPicker,
           case .recording = appState.state {
            return "inputPicker"
        }
        if let phase = appState.assistantSession?.phase {
            switch phase {
            case .planning, .executing:
                return "toolWorking"
            default:
                break
            }
        }
        if isProcessingState,
           !appState.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "transcript"
        }
        switch appState.state {
        case .idle: return "idle"
        case .recording, .cancelled: return "listening"
        case .transcribing, .refining, .result, .dismissing: return "processing"
        case .error: return "error"
        }
    }


    /// Extra height reserved for the input device picker.
    /// Always included (even when picker is closed) so the panel and body frame
    /// never resize for picker open/close - SwiftUI handles the visual animation.
    /// Must match OverlayPanel.pickerExtraHeight exactly.
    private var pickerExtraHeight: CGFloat {
        let deviceCount = max(appState.inputDevices.count, 1)
        // 28 header + one row per device + 26 for the "Follow system default"
        // row + 12 padding + 1 hairline. Must match OverlayPanel.
        return 28 + CGFloat(deviceCount) * 26 + 26 + 12 + 1
    }

    var body: some View {
        Group {
            if appState.overlayUsesTopEdgeSurface {
                notchAttachedSurface
            } else {
                if let assistantCard = appState.assistantCard {
                    assistantCardView(assistantCard)
                } else if appState.fallbackResult != nil {
                    // The take had no text field to land in - show it in a
                    // card with a Copy escape hatch instead of losing it.
                    fallbackResultCard
                } else {
                    switch appState.state {
                    case .idle:
                        Color.clear.frame(width: 0, height: 0)
                    case .recording, .cancelled,
                         .transcribing, .refining, .result, .dismissing:
                        floatingRecordingView
                    case .error(let message):
                        errorView(message: message)
                    }
                }
            }
        }
        .frame(width: 420)
        .padding(.top, appState.overlayUsesTopEdgeSurface ? 0 : 10)
        .frame(height: panelContentHeight, alignment: .top)
        .animation(
            appState.suppressStateAnimation
                ? nil
                : .spring(response: 0.46, dampingFraction: 0.88, blendDuration: 0.12),
            value: notchPresentation
        )
        .animation(appState.suppressStateAnimation ? nil : .spring(response: 0.24, dampingFraction: 0.85), value: appState.state)
        // The microphone list is revealed by clipping one continuous notch
        // surface, so a calm non-bouncy curve reads more like native system UI
        // than a cross-fade between two independently springing views.
        .animation(.smooth(duration: 0.32), value: appState.showingInputPicker)
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: appState.fallbackResult != nil)
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: appState.assistantCard)
    }

    // MARK: - Assistant glance + confirmation cards

    private func assistantCardView(_ card: AssistantCard) -> some View {
        assistantCardContent(card)
            .assistantCardChrome()
    }

    @ViewBuilder
    private func assistantCardContent(_ card: AssistantCard) -> some View {
        switch card {
        case .fileResults(let query, let results):
            VStack(alignment: .leading, spacing: 12) {
                assistantCardHeader(
                    symbol: "folder.badge.magnifyingglass",
                    title: "Finder",
                    subtitle: "Spotlight · On-device"
                )

                assistantRequestLine
                assistantToolStatusChip

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("\(query) — \(results.count) items")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.32))
                    }

                    if !results.isEmpty {
                        HStack(spacing: 6) {
                            Text("Name")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Size")
                                .frame(width: 42, alignment: .trailing)
                            Text("Modified")
                                .frame(width: 66, alignment: .trailing)
                        }
                        .padding(.leading, 24)
                        .padding(.trailing, 5)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.32))
                    }

                    if results.isEmpty {
                        Text("No matching files found on this Mac.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.vertical, 18)
                    } else {
                        ForEach(Array(results.prefix(8))) { result in
                            assistantFileRow(result)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
                )

                HStack {
                    Text("I found \(results.count) matching items on this Mac.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                    Spacer(minLength: 8)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

        case .confirmOpen(let result):
            VStack(alignment: .leading, spacing: 14) {
                assistantCardHeader(
                    symbol: "hand.raised.fill",
                    title: "Open this file?",
                    subtitle: "Confirmation required"
                )

                assistantRequestLine
                assistantToolStatusChip

                HStack(spacing: 11) {
                    Image(systemName: result.symbolName)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.blue.opacity(0.9))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.08)))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                        Text(result.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                    }
                }
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
                )

                HStack(spacing: 8) {
                    assistantCardButton("Cancel", prominent: false) {
                        appState.dismissAssistantCard()
                    }
                    assistantCardButton("Open", prominent: true) {
                        appState.approveAssistantAction()
                    }
                }
            }

        case .calendarDraft(let draft):
            VStack(alignment: .leading, spacing: 12) {
                assistantCardHeader(
                    symbol: "calendar",
                    title: "New Event",
                    subtitle: "Review before saving"
                )

                assistantRequestLine
                assistantToolStatusChip

                VStack(alignment: .leading, spacing: 12) {
                    Text(draft.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(2)

                    Rectangle()
                        .fill(Color(red: 0.24, green: 0.52, blue: 1.0))
                        .frame(height: 2)

                    HStack(spacing: 9) {
                        Image(systemName: "clock")
                            .foregroundStyle(.white.opacity(0.52))
                        Text(calendarIntervalLabel(draft))
                            .foregroundStyle(.white.opacity(0.82))
                    }

                    if !draft.attendeeEmails.isEmpty {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "person")
                                .foregroundStyle(.white.opacity(0.52))
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(draft.attendeeEmails, id: \.self) { email in
                                    Text(email)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(Color(red: 0.72, green: 0.82, blue: 1.0))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color(red: 0.18, green: 0.23, blue: 0.33)))
                                }
                            }
                        }
                    }

                    if let location = draft.location, !location.isEmpty {
                        Label(location, systemImage: "location")
                            .foregroundStyle(.white.opacity(0.66))
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .padding(13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
                )

                if !draft.attendeeEmails.isEmpty {
                    Label("Invitees are saved in the event notes; no invitation is sent.", systemImage: "info.circle")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.34))
                }

                HStack(spacing: 8) {
                    assistantCardButton("Cancel", prominent: false) {
                        appState.dismissAssistantCard()
                    }
                    assistantCardButton("Save", prominent: true) {
                        appState.approveAssistantAction()
                    }
                }
            }

        case .webSearch(let draft):
            VStack(alignment: .leading, spacing: 12) {
                assistantCardHeader(
                    symbol: "globe",
                    title: "Web Search",
                    subtitle: "Opens your default browser"
                )

                assistantRequestLine
                assistantToolStatusChip

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                    Text(draft.query)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(3)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
                )

                HStack(spacing: 8) {
                    assistantCardButton("Cancel", prominent: false) {
                        appState.dismissAssistantCard()
                    }
                    assistantCardButton("Search", prominent: true) {
                        appState.approveAssistantAction()
                    }
                }
            }

        case .message(let symbol, let title, let detail):
            VStack(alignment: .leading, spacing: 10) {
                assistantCardHeader(symbol: symbol, title: title, subtitle: "Whisperino")
                assistantRequestLine
                assistantToolStatusChip
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                assistantTraceStrip
            }
        }
    }

    @ViewBuilder
    private var assistantRequestLine: some View {
        if let transcript = appState.assistantSession?.transcript,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(transcript)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var assistantToolStatusChip: some View {
        let status = assistantToolStatus
        return HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(status.label)
                .font(.system(size: 9, weight: .semibold))
            if status.complete {
                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .bold))
            }
        }
        .foregroundStyle(.white.opacity(0.48))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.07)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantToolStatus: (label: String, symbol: String, complete: Bool) {
        guard let phase = appState.assistantSession?.phase else {
            return ("Ready", "sparkles", true)
        }
        switch phase {
        case .planning:
            return ("Planning", "sparkles", false)
        case .executing(let toolID):
            return (toolLabel(toolID, active: true), "magnifyingglass", false)
        case .awaitingConfirmation(let invocation):
            return (toolLabel(invocation.toolID, active: false), "checkmark.circle", true)
        case .presenting:
            if case .fileResults = appState.assistantCard {
                return ("Searching", "magnifyingglass", true)
            }
            return ("Tool completed", "checkmark.circle", true)
        case .failed:
            return ("Tool failed", "exclamationmark.triangle", false)
        default:
            return ("Ready", "sparkles", false)
        }
    }

    private func toolLabel(_ id: String, active: Bool) -> String {
        switch id {
        case LocalFinderAssistantTool.id: return active ? "Searching this Mac" : "Search ready"
        case OpenLocalFileAssistantTool.id: return active ? "Opening file" : "Ready to open"
        case CreateCalendarEventAssistantTool.id: return active ? "Saving event" : "Event ready"
        case WebSearchAssistantTool.id: return active ? "Searching" : "Search ready"
        default: return active ? "Working" : "Ready"
        }
    }

    private func calendarIntervalLabel(_ draft: CalendarEventDraft) -> String {
        let weekday = DateFormatter.localizedString(from: draft.start, dateStyle: .full, timeStyle: .none)
        let start = DateFormatter.localizedString(from: draft.start, dateStyle: .none, timeStyle: .short)
        let end = DateFormatter.localizedString(from: draft.end, dateStyle: .none, timeStyle: .short)
        return "\(weekday) · \(start) - \(end)"
    }

    @ViewBuilder
    private var assistantTraceStrip: some View {
        if let steps = appState.assistantSession?.trace, !steps.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 9, weight: .semibold))
                Text(steps.suffix(2).joined(separator: "  →  "))
                    .lineLimit(1)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.34))
        }
    }

    private func assistantCardHeader(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.1)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.07)))
                .contentShape(Circle())
                .onTapGesture { appState.dismissAssistantCard() }
                .pointerOnHover()
        }
    }

    private func assistantFileRow(_ result: LocalFileResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: result.symbolName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 18, height: 18)

            Text(result.name)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.sizeLabel ?? "—")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 42, alignment: .trailing)

            Text(result.modifiedLabel ?? "—")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.045)))
        .contentShape(Rectangle())
        .onTapGesture { appState.requestOpen(result) }
        .pointerOnHover()
    }

    private func assistantCardButton(
        _ label: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(prominent ? 0.98 : 0.82))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        prominent
                            ? Color(red: 0.23, green: 0.51, blue: 1.0)
                            : Color.white.opacity(0.09)
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .pointerOnHover()
    }

    // MARK: - Fallback result card (nothing focused to paste into)

    @State private var copiedFallback = false
    @State private var isHoveringFallbackCopy = false
    @State private var fallbackProgress: CGFloat = 0

    /// Wispr-style rescue card: the transcription couldn't be pasted
    /// (no focused text field), so it's shown here with a Copy button
    /// instead of silently vanishing.
    private var fallbackResultCard: some View {
        fallbackResultContent
            .fallbackCardChrome()
    }

    private var fallbackResultContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appState.fallbackResult ?? "")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.leading)
                .lineSpacing(4)
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Text(copiedFallback ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(.white.opacity(isHoveringFallbackCopy ? 0.16 : 0.10))
                    )
                    .contentShape(Rectangle())
                    .onHover { isHoveringFallbackCopy = $0 }
                    .onTapGesture {
                        guard !copiedFallback else { return }
                        appState.copyToClipboard(appState.fallbackResult ?? "")
                        copiedFallback = true
                        // Brief "Copied" confirmation, then the card has
                        // done its job.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            appState.dismissFallback()
                            copiedFallback = false
                        }
                    }
                    .pointerOnHover()
            }
        }
        .onAppear(perform: restartFallbackProgress)
        .onChange(of: appState.fallbackResult) { _, result in
            if result != nil { restartFallbackProgress() }
        }
    }

    private func restartFallbackProgress() {
        withAnimation(nil) { fallbackProgress = 0 }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: AppState.fallbackTimeout)) {
                fallbackProgress = 1
            }
        }
    }

    /// Vertical room the SwiftUI body claims inside the panel. Must match
    /// `OverlayPanel.panelHeight`.
    private var panelContentHeight: CGFloat {
        380 + pickerExtraHeight
    }

    @State private var isHoveringPill = false
    @State private var isHoveringMic = false
    @State private var isHoveringWaveform = false
    @State private var isHoveringLatchedCancel = false
    @State private var isHoveringLatchedSubmit = false
    @State private var isHoveringNotchMeter = false
    @State private var isHoveringNotchCancel = false
    /// Drives the pulsing orange ping around the mic button while the
    /// no-audio nudge is showing.
    @State private var micPulse = false

    // MARK: - Recording

    /// External displays have no camera housing to clear. Their virtual island
    /// can therefore stay noticeably narrower than the MacBook treatment,
    /// leaving room for macOS's orange microphone privacy indicator even when
    /// the right side of the menu bar is crowded.
    private var usesExternalTopEdgeIsland: Bool {
        appState.overlayUsesTopEdgeSurface && !appState.overlayHasPhysicalNotch
    }

    private var notchSurfaceWidth: CGFloat {
        switch notchPresentation {
        case "assistant", "fallback", "toolWorking", "transcript": return 360
        // Never shrink horizontally when opening on a wide hardware notch.
        // The selector grows outward from the compact recording width.
        // Keep the selector content at the compact recording width. Only the
        // notch's vertical body and reverse corners morph, so list rows never
        // reflow sideways during dismissal.
        case "inputPicker":
            return usesExternalTopEdgeIsland
                ? 224
                : max(appState.overlayPhysicalNotchWidth + 72, 260)
        case "error":
            return usesExternalTopEdgeIsland
                ? 272
                : max(appState.overlayPhysicalNotchWidth + 72, 292)
        // Keep the compact recording wings clear of macOS's orange microphone
        // privacy indicator. Thirty-six points per side gives the meter hover
        // treatment a little breathing room without returning to the earlier
        // oversized footprint; the selector can still grow when opened.
        default:
            return usesExternalTopEdgeIsland
                ? 224
                : max(appState.overlayPhysicalNotchWidth + 72, 260)
        }
    }

    /// A slightly more pronounced take on the established macOS notch radii.
    /// It remains independent of the full menu-bar height so the edge reads
    /// clearly without ever turning back into a long funnel.
    private var notchTopCornerRadius: CGFloat {
        // Opening the microphone picker must be a vertical-only operation.
        // Keeping the recording shoulder radius constant prevents the shell's
        // total width from changing by 22pt while a selected row dismisses.
        if case .recording = appState.state { return 10 }
        return notchIsExpanded ? 21 : 10
    }

    private var notchShellWidth: CGFloat {
        notchSurfaceWidth + notchTopCornerRadius * 2
    }

    private var notchIsExpanded: Bool {
        notchPresentation == "assistant"
            || notchPresentation == "fallback"
            || notchPresentation == "toolWorking"
            || notchPresentation == "transcript"
            || notchPresentation == "inputPicker"
            || notchPresentation == "error"
    }

    /// One continuous shell, pinned to the physical camera housing. Listening,
    /// working and result states are content phases inside this same view; its
    /// dimensions and bottom corners spring between phases without ever
    /// becoming a detached pill or a replacement card.
    @ViewBuilder
    private var notchAttachedSurface: some View {
        if notchPresentation == "idle" {
            Color.clear.frame(width: 0, height: 0)
        } else {
            let bottomRadius: CGFloat = notchIsExpanded ? 24 : 14
            let inAIContext = appState.isInstructionMode || appState.isAgentMode
            let usesToolAccent = notchPresentation == "assistant"
                || notchPresentation == "toolWorking"
            let usesLiftedShadow = notchIsExpanded
                && notchPresentation != "inputPicker"
            // DynamicNotchKit/Boring Notch's proven reverse-corner geometry:
            // a small outward top fillet, straight body sides, rounded chin.
            let notchShape = NativeNotchShape(
                topCornerRadius: notchTopCornerRadius,
                bottomRadius: bottomRadius
            )

            ZStack(alignment: .top) {
                Group {
                    if case .recording = appState.state {
                        recordingNotchBody
                    } else if notchIsExpanded {
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: max(appState.overlayNotchInset, 28))

                            notchAttachedContent
                                .id(notchPresentation)
                                .transition(
                                    .opacity.combined(
                                        with: .scale(scale: 0.985, anchor: .top)
                                    )
                                )
                        }
                    } else {
                        compactNotchContent
                    }
                }
                .frame(width: notchSurfaceWidth)
                .frame(width: notchShellWidth)
                .background(
                    ZStack {
                        Color.black
                        LinearGradient(
                            colors: notchIsExpanded && usesToolAccent
                                ? [
                                    Color.black,
                                    Color(red: 0.035, green: 0.045, blue: 0.075),
                                  ]
                                : [
                                    Color.black,
                                    inAIContext
                                        ? Color(red: 0.075, green: 0.085, blue: 0.15)
                                        : Color(red: 0.015, green: 0.018, blue: 0.024),
                                  ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                )
                .clipShape(notchShape)
                .overlay(alignment: .bottom) {
                    Group {
                        if notchPresentation != "fallback" {
                            LinearGradient(
                                colors: [
                                    .clear,
                                    notchIsExpanded && usesToolAccent
                                        ? Color(red: 0.18, green: 0.42, blue: 1).opacity(0.42)
                                        : Color.white.opacity(notchIsExpanded ? 0.10 : 0.14),
                                    .clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(height: 1)
                            .padding(.horizontal, notchIsExpanded ? 22 : 18)
                            .transition(.identity)
                        }
                    }
                    // The lifetime contour replaces this hairline. Do not fade
                    // one through the other or both are visible after a take.
                    .animation(nil, value: notchPresentation)
                }
                .overlay {
                    if notchPresentation == "fallback" {
                        let lifetimeTrack = FallbackPerimeterProgress(
                                progress: 1,
                                topCornerRadius: notchTopCornerRadius,
                                bottomRadius: bottomRadius
                            )
                        let lifetimeContour = FallbackPerimeterProgress(
                                progress: fallbackProgress,
                                topCornerRadius: notchTopCornerRadius,
                                bottomRadius: bottomRadius
                            )

                        ZStack {
                            // A quiet full route makes the timer readable as a
                            // perimeter control before any progress accumulates.
                            // Insetting keeps every pixel over the black shell,
                            // so white windows cannot erase half the stroke.
                            lifetimeTrack
                                .stroke(
                                    fallbackLifetimeGradient(peakOpacity: 0.17),
                                    style: StrokeStyle(
                                        lineWidth: 0.85,
                                        lineCap: .round,
                                        lineJoin: .round
                                    )
                                )
                                .padding(1.25)

                            // The filled lifetime is a crisp neutral line with
                            // one soft shadow—not a second blurred duplicate.
                            // This holds contrast over light, saturated, and
                            // dark backgrounds without introducing a blue halo.
                            lifetimeContour
                                .stroke(
                                    fallbackLifetimeGradient(peakOpacity: 0.90),
                                    style: StrokeStyle(
                                        lineWidth: 1.15,
                                        lineCap: .round,
                                        lineJoin: .round
                                    )
                                )
                                .padding(1.25)
                                .shadow(color: .white.opacity(0.34), radius: 1.6)
                        }
                    }
                }
                .shadow(
                    color: usesLiftedShadow
                        ? (usesToolAccent
                            ? Color(red: 0.05, green: 0.32, blue: 1.0).opacity(0.28)
                            : Color.black.opacity(0.32))
                        : .clear,
                    radius: usesLiftedShadow ? 18 : 0,
                    y: usesLiftedShadow ? 7 : 0
                )
                .scaleEffect((isCancelled || isDismissing) ? 0.97 : 1, anchor: .top)
                .opacity((isCancelled || isDismissing) ? 0 : 1)
                .blur(radius: (isCancelled || isDismissing) ? 2 : 0)
                .animation(
                    .smooth(duration: 0.34),
                    value: notchShellWidth
                )
                .animation(
                    .smooth(duration: 0.34),
                    value: notchIsExpanded
                )
                .animation(.easeOut(duration: 0.14), value: isCancelled || isDismissing)

                // Recording controls live on a fixed-size canvas that is a
                // sibling of the morphing shell. Their global coordinates do
                // not depend on the shell's current or interpolated bounds.
                if case .recording = appState.state {
                    recordingNotchControls
                        .frame(
                            width: 420,
                            height: max(appState.overlayNotchInset, 28),
                            alignment: .top
                        )
                        .zIndex(10)
                        .animation(nil, value: appState.showingInputPicker)
                }
            }
            .frame(width: 420, alignment: .top)
        }
    }

    /// Fade the lifetime contour at the two points where the notch meets the
    /// menu bar. The broad middle remains legible as the path fills around the
    /// chin; only the outer joins dissolve into the hardware silhouette.
    private func fallbackLifetimeGradient(peakOpacity: Double) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(peakOpacity * 0.18), location: 0.022),
                .init(color: .white.opacity(peakOpacity * 0.76), location: 0.052),
                .init(color: .white.opacity(peakOpacity), location: 0.085),
                .init(color: .white.opacity(peakOpacity), location: 0.915),
                .init(color: .white.opacity(peakOpacity * 0.76), location: 0.948),
                .init(color: .white.opacity(peakOpacity * 0.18), location: 0.978),
                .init(color: .white.opacity(0), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @ViewBuilder
    private var notchAttachedContent: some View {
        if let card = appState.assistantCard {
            assistantCardContent(card)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        } else if appState.fallbackResult != nil {
            fallbackResultContent
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        } else {
            switch appState.state {
            case .recording, .cancelled:
                if notchPresentation == "inputPicker" {
                    physicalNotchInputPicker
                } else {
                    EmptyView()
                }
            case .transcribing, .refining, .result, .dismissing:
                if notchPresentation == "toolWorking" {
                    VStack(alignment: .leading, spacing: 9) {
                        assistantRequestLine
                        assistantToolStatusChip
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                } else if notchPresentation == "transcript" {
                    liveTranscriptPreview
                } else {
                    EmptyView()
                }
            case .error(let message):
                let presentation = errorPresentation(for: message)
                HStack(spacing: 10) {
                    Image(systemName: presentation.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(presentation.tint.opacity(0.92))
                        .frame(width: 25, height: 25)
                        .background(
                            Circle().fill(presentation.tint.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.90))
                            .lineLimit(1)

                        if let detail = presentation.detail {
                            Text(detail)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.46))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 7)
                .padding(.bottom, 14)
            case .idle:
                EmptyView()
            }
        }
    }

    private var compactHardwareWidth: CGFloat {
        if usesExternalTopEdgeIsland { return 160 }
        return min(
            max(appState.overlayPhysicalNotchWidth, 170),
            notchSurfaceWidth - 48
        )
    }

    private var compactWingWidth: CGFloat {
        (notchSurfaceWidth - compactHardwareWidth) / 2
    }

    /// Recording controls are pinned to the physical camera housing rather
    /// than the animated shell. The shell may widen for the source picker,
    /// but these coordinates never change, so the live meter cannot slide
    /// underneath the hardware notch or drift sideways during the morph.
    private var recordingControlWingWidth: CGFloat { 32 }

    private var recordingHardwareWidth: CGFloat {
        if usesExternalTopEdgeIsland { return 160 }
        return max(appState.overlayPhysicalNotchWidth, 170)
    }

    private var recordingControlsWidth: CGFloat {
        recordingHardwareWidth + recordingControlWingWidth * 2
    }

    /// Exact intrinsic height of the physical-notch microphone chooser. The
    /// recording shell animates this amount from zero while clipping the list,
    /// which makes it slide back into the notch instead of fading or swapping.
    private var physicalPickerBodyHeight: CGFloat {
        if appState.inputDevices.isEmpty { return 66 }
        // 19pt section label + 8pt picker-internal vertical padding +
        // 9pt outer bottom inset, plus one 33pt row per route. Together with
        // the picker's own 4pt inset this leaves a balanced 13pt at the chin.
        return 36 + CGFloat(appState.inputDevices.count + 1) * 33
    }

    /// Recording always owns one stable view tree. Opening the selector simply
    /// reveals more of it below the hardware inset; closing reverses that same
    /// geometry, so the live meter never gets recreated or stutters.
    private var recordingNotchBody: some View {
        let notchHeight = max(appState.overlayNotchInset, 28)
        let visibleHeight = notchHeight
            + (appState.showingInputPicker ? physicalPickerBodyHeight : 0)

        return VStack(spacing: 0) {
            Color.clear
                .frame(height: notchHeight)

            physicalNotchInputPicker
                .frame(height: physicalPickerBodyHeight, alignment: .top)
                .animation(nil, value: appState.showingInputPicker)
        }
        .frame(width: notchSurfaceWidth)
        .frame(height: visibleHeight, alignment: .top)
        .clipped()
    }

    /// Compact recording and processing occupy only the physical notch's
    /// height. The center remains reserved for the camera housing while the
    /// activity signal slides into the symmetric left extension.
    @ViewBuilder
    private var compactNotchContent: some View {
        HStack(spacing: 0) {
            Group {
                switch appState.state {
                case .recording, .cancelled:
                    Color.clear
                case .transcribing, .refining, .result, .dismissing:
                    NotchProcessingDots()
                default:
                    Color.clear
                }
            }
            .frame(width: compactWingWidth, height: max(appState.overlayNotchInset, 28))

            Color.clear
                .frame(width: compactHardwareWidth)

            Color.clear
                .frame(width: compactWingWidth)
        }
        .frame(
            width: notchSurfaceWidth,
            height: max(appState.overlayNotchInset, 28)
        )
    }

    /// The physical camera housing remains a dead center zone. Recording
    /// controls live in the two small menu-bar wings that the notch opens on
    /// either side: live input on the left, destructive cancel on the right.
    private var recordingNotchControls: some View {
        HStack(spacing: 0) {
            notchMeterButton
                .frame(width: recordingControlWingWidth)

            Color.clear
                .frame(width: recordingHardwareWidth)
                .allowsHitTesting(false)

            notchCancelButton
                .frame(width: recordingControlWingWidth)
        }
        .frame(
            width: recordingControlsWidth,
            height: max(appState.overlayNotchInset, 28)
        )
        // This overlay deliberately has no frame derived from the animated
        // shell. SwiftUI therefore has no horizontal geometry to interpolate
        // when the picker opens or closes: both controls remain screen-locked
        // while the black surface grows around them. Suppress only the picker
        // transaction here; audio-level animations inside the meter remain
        // active and responsive.
        .animation(nil, value: appState.showingInputPicker)
    }

    /// The audio visualization is also the source selector. Its quiet hover
    /// plate makes the affordance discoverable without turning it into a
    /// separate button floating beside the hardware notch.
    private var notchMeterButton: some View {
        Button {
            appState.noAudioDetected = false
            appState.showingInputPicker.toggle()
        } label: {
            subtleVolumeIndicator
                .frame(width: 30, height: 22)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            Color.white.opacity(
                                appState.showingInputPicker
                                    ? 0.13
                                    : (isHoveringNotchMeter ? 0.09 : 0)
                            )
                        )
                )
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(
                                appState.showingInputPicker
                                    ? 0.19
                                    : (isHoveringNotchMeter ? 0.12 : 0)
                            ),
                            lineWidth: 0.75
                        )
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHoveringNotchMeter = $0 }
        .pointerOnHover()
        .help("Choose microphone")
        .accessibilityLabel("Choose microphone")
        .animation(.easeInOut(duration: 0.14), value: isHoveringNotchMeter)
        .animation(.easeInOut(duration: 0.14), value: appState.showingInputPicker)
    }

    /// Cancel is intentionally quieter than the audio meter until hovered,
    /// then warms slightly to communicate that it discards the current take.
    private var notchCancelButton: some View {
        Button {
            appState.cancelRecording()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(
                    isHoveringNotchCancel
                        ? Color.white
                        : Color.white.opacity(0.68)
                )
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(
                        isHoveringNotchCancel
                            ? Color(red: 0.72, green: 0.18, blue: 0.18).opacity(0.86)
                            : Color.white.opacity(0.075)
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(isHoveringNotchCancel ? 0.18 : 0.09),
                        lineWidth: 0.75
                    )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHoveringNotchCancel = $0 }
        .pointerOnHover()
        .help("Cancel transcription")
        .accessibilityLabel("Cancel transcription")
        .animation(.easeInOut(duration: 0.14), value: isHoveringNotchCancel)
    }

    /// Expanded source chooser. This is content inside the existing notch
    /// shell—not a detached menu—so opening it morphs the island itself.
    private var physicalNotchInputPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Input source")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.38))
                .textCase(.uppercase)
                .tracking(0.35)
                .padding(.horizontal, 15)
                .padding(.top, 8)

            InputDevicePicker(
                appState: appState,
                isPresented: $appState.showingInputPicker,
                showsHeader: false
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 9)
        }
        .frame(width: notchSurfaceWidth)
    }

    private var subtleVolumeIndicator: some View {
        NotchListeningBars(
            samples: appState.audioSamples,
            noAudioDetected: appState.noAudioDetected
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var liveTranscriptPreview: some View {
        Text(appState.liveTranscript)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white.opacity(0.88))
            .lineSpacing(4)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            )
    }

    /*
     The external-display recorder keeps the compact floating control cluster;
     the physical-notch path above intentionally has no permanent mic, cancel
     or submit buttons. Fn/Return/Escape remain available from the keyboard.
     */
    private var floatingRecordingView: some View {
        let cancelled = isCancelled
        // Recording stopped → same pill, typing-flow content. Applies to both
        // raw dictation and AI takes: once the mic closes, the waveform hands
        // over to the typing flow while transcription / generation runs.
        let processing = isProcessingState
        // The latched cluster - mic-select ○, ✕ to discard, waveform, ✓ to
        // submit - is the persistent anchor while the mic is open in AI mode
        // (or any latched take), rather than a plain waveform.
        let latched = (appState.isLatchedRecording
            || appState.isInstructionMode || appState.isAgentMode)
            && !cancelled && !processing
        // Every pill is a full capsule, 30pt tall in all modes (radius 15 =
        // half height): waveform row 16pt + 7 padding; latched swaps in 22pt
        // ✕/✓ buttons with 4pt padding — same 30pt.
        let pillRadius: CGFloat = 15
        return ZStack {
            // Wispr-style cluster: mic satellite + pill in one bottom-aligned
            // HStack. The mic circle is exactly the pill's height (30pt), so
            // bottom alignment IS center alignment. Only shown in latched
            // mode; hold-to-talk takes are too quick for device switching.
            HStack(alignment: .bottom, spacing: 4) {
            if latched {
                micSelectorButton
                    .transition(.scale.combined(with: .opacity))
            }

            // The bottom pill: the live waveform, or the typing flow while
            // transcription / AI generation runs.
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if processing {
                        // Same pill, new content: the typing flow takes the
                        // waveform's place and the pill springs wider to fit.
                        // In Rafterino mode your words drift by as a message
                        // in a bottle instead.
                        Group {
                            if rafterino {
                                RafterinoBottleFlowView()
                            } else {
                                TypingFlowView()
                            }
                        }
                        .frame(height: 16)
                        .transition(.opacity)
                    } else {
                        if latched {
                            latchedCancelButton
                                .transition(.scale.combined(with: .opacity))
                        }

                        // Live level display: the classic bar waveform, or -
                        // in Rafterino mode - the sea itself, with the raft
                        // riding the wave your voice makes.
                        Group {
                            if rafterino {
                                RafterinoLiveWaveView(samples: appState.audioSamples)
                            } else {
                                HStack(spacing: 2) {
                                    ForEach(0..<AppState.waveformBarCount, id: \.self) { i in
                                        Capsule()
                                            .fill(.white.opacity(0.78))
                                            .frame(width: 2, height: barHeight(for: i))
                                    }
                                }
                            }
                        }
                        .frame(height: 16)
                        .transition(.opacity)

                        if latched {
                            latchedSubmitButton
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, latched ? 4 : 11)
                .padding(.vertical, latched ? 4 : 7)
                .contentShape(Rectangle())
                .onHover { isHoveringWaveform = $0 }
                .onTapGesture {
                    // Latched mode carries explicit ✕ / ✓ controls, so a tap
                    // on the pill body is a no-op (a stray click shouldn't end
                    // the take). The plain hold-to-talk pill still toggles
                    // recording on body tap.
                    if !processing && !latched {
                        appState.toggleRecording()
                    }
                }
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
            .overlay(
                Group {
                    if cancelled {
                        EmptyView()
                    } else if isHoveringLatchedCancel {
                        GlowBorder(cornerRadius: pillRadius, color: Color(red: 0.9, green: 0.25, blue: 0.25))
                    } else if isHoveringLatchedSubmit {
                        GlowBorder(cornerRadius: pillRadius, color: Color(red: 0.25, green: 0.78, blue: 0.45))
                    } else if !latched && isHoveringWaveform {
                        GlowBorder(cornerRadius: pillRadius, color: Color(red: 0.25, green: 0.78, blue: 0.45))
                    } else if !latched && isHoveringPill {
                        GlowBorder(cornerRadius: pillRadius, color: Color(red: 0.25, green: 0.78, blue: 0.45))
                    } else {
                        // Calm dictation border vs. animated AI gradient.
                        // Gradient applies whenever we're in AI mode.
                        // Rafterino mode trades the calm hairline for slow
                        // water; the AI rainbow still wins - mode identity
                        // beats theming.
                        let inAIContext = appState.isInstructionMode || appState.isAgentMode
                        ZStack {
                            RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                                .opacity(inAIContext || rafterino ? 0 : 1)
                            if rafterino {
                                RafterinoWaterBorder(cornerRadius: pillRadius)
                                    .opacity(inAIContext ? 0 : 1)
                            }
                            AnimatedGradientBorder(cornerRadius: pillRadius)
                                .opacity(inAIContext ? 1 : 0)
                        }
                        .animation(.easeInOut(duration: 0.35), value: inAIContext)
                    }
                }
            )
            // Exit - cancel and done share one gesture: the pill stays
            // put, slightly scales down, blurs and fades, all in 0.14s.
            .scaleEffect((cancelled || isDismissing) ? 0.9 : 1.0)
            .opacity((cancelled || isDismissing) ? 0 : 1)
            .blur(radius: (cancelled || isDismissing) ? 4 : 0)
            .animation(.easeOut(duration: 0.14), value: cancelled || isDismissing)
            // Width morph when the waveform hands over to the typing
            // flow - springy so the pill visibly *grows* into the
            // transcribing state rather than snapping.
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: processing)
            }
            // Input device picker for latched takes - anchored to the mic
            // satellite, popping out like a menu.
            .overlay(alignment: .topLeading) {
                if appState.showingInputPicker && latched {
                    inputDevicePickerCard
                        .offset(y: 36)
                        .transition(
                            .scale(scale: 0.96, anchor: .topLeading)
                                .combined(with: .opacity)
                        )
                }
            }
        }
        // "We're recording but hearing nothing" nudge, floated just above the
        // pill without displacing it - the pill stays the stable anchor. Only
        // while the mic is actually open (not during the typing-flow handover
        // or a cancel).
        .overlay(alignment: .bottom) {
            // Hidden while the input picker is open - the picker sprouts from
            // the same mic button and would otherwise overlap the nudge.
            if appState.noAudioDetected && !processing && !cancelled
                && !appState.showingInputPicker {
                noAudioNudge
                    .offset(y: 42)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: appState.noAudioDetected)
        .animation(.easeOut(duration: 0.15), value: appState.showingInputPicker)
        .onHover { hovering in
            isHoveringPill = hovering
        }
        .animation(.easeOut(duration: 0.16), value: appState.audioSamples)
        .animation(.easeInOut(duration: 0.15), value: isHoveringPill)
        .animation(.easeInOut(duration: 0.15), value: isHoveringMic)
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: appState.isLatchedRecording)
    }

    /// The input-device picker in its floating panel chrome, anchored to the
    /// mic satellite. Same dark panel + hairline border as the pill.
    private var inputDevicePickerCard: some View {
        InputDevicePicker(appState: appState, isPresented: $appState.showingInputPicker)
            .frame(width: 240)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
            )
    }

    /// Mic circle to the left of the pill - exactly the latched row's
    /// height (32pt) and the same chrome (black, hairline border), so
    /// the cluster reads like one segmented control, Wispr-style.
    /// Click toggles the input device picker.
    private var micSelectorButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(isHoveringMic ? 1 : 0.8))
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.black))
            .overlay(
                Circle().strokeBorder(
                    isHoveringMic || appState.showingInputPicker
                        ? Color(red: 0.95, green: 0.55, blue: 0.15).opacity(0.8)
                        : Color.white.opacity(0.32),
                    lineWidth: 1
                )
            )
            // Pulsing orange ping while the nudge is up - draws the eye to the
            // mic button as the place to fix a dead input.
            .overlay {
                if appState.noAudioDetected {
                    Circle()
                        .stroke(Color(red: 0.95, green: 0.55, blue: 0.15), lineWidth: 1.5)
                        .scaleEffect(micPulse ? 1.18 : 1.0)
                        .opacity(micPulse ? 0 : 0.55)
                        .animation(
                            .easeOut(duration: 1.3).repeatForever(autoreverses: false),
                            value: micPulse
                        )
                        .onAppear { micPulse = true }
                        .onDisappear { micPulse = false }
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Circle())
            .onHover { isHoveringMic = $0 }
            .onTapGesture {
                // The picker springs from here, so the nudge (which points at
                // this button) has served its purpose - clear it immediately
                // so the two never overlap.
                appState.noAudioDetected = false
                appState.showingInputPicker.toggle()
            }
            .pointerOnHover()
            .animation(.easeInOut(duration: 0.1), value: isHoveringMic)
    }

    // MARK: - Latched-recording controls (✕ / ✓ inline in the pill)

    /// Discard the take. Gray circle, white ✕ - turns red on hover like
    /// the corner cancel button so "destructive" reads the same everywhere.
    private var latchedCancelButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(isHoveringLatchedCancel ? 1 : 0.9))
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(
                    isHoveringLatchedCancel
                        ? Color(red: 0.8, green: 0.2, blue: 0.2)
                        : Color(white: 0.32)
                )
            )
            .contentShape(Circle())
            .onHover { isHoveringLatchedCancel = $0 }
            .onTapGesture { appState.cancelRecording() }
            .pointerOnHover()
            .animation(.easeInOut(duration: 0.1), value: isHoveringLatchedCancel)
    }

    /// Submit the take. White circle, dark ✓ - the affirmative twin of
    /// the cancel button.
    private var latchedSubmitButton: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(.white.opacity(isHoveringLatchedSubmit ? 1 : 0.9))
            )
            .contentShape(Circle())
            .onHover { isHoveringLatchedSubmit = $0 }
            .onTapGesture { appState.submitOrFinish() }
            .pointerOnHover()
            .animation(.easeInOut(duration: 0.1), value: isHoveringLatchedSubmit)
    }

    /// Gentle shape mask - barely attenuates the edges so the wave is
    /// visibly present across the whole pill as it rolls right-to-left,
    /// rather than collapsing to a right-side spike.
    private static let barShape: [CGFloat] = [
        0.80, 0.85, 0.90, 0.94, 0.97, 1.0, 1.0,
        1.0, 0.97, 0.94, 0.90, 0.85, 0.80
    ]

    private func barHeight(for index: Int) -> CGFloat {
        let samples = appState.audioSamples
        guard samples.indices.contains(index) else { return 3 }
        // Spatial smoothing - blend each sample with its neighbours [1,2,1]/4
        // so a single-tick spike in one buffer position gets diluted into a
        // smooth crest instead of a jagged jump.
        let curr = CGFloat(samples[index])
        let prev = index > 0 ? CGFloat(samples[index - 1]) : curr
        let next = index < samples.count - 1 ? CGFloat(samples[index + 1]) : curr
        let smoothed = (prev + curr * 2 + next) / 4
        let shape = Self.barShape.indices.contains(index) ? Self.barShape[index] : 1.0
        // pow < 1 lifts quiet speech into clearly visible motion -
        // linear mapping left normal talking almost flat.
        let boosted = pow(smoothed, 0.6)
        return max(3, min(16, 3 + boosted * shape * 13))
    }

    // MARK: - No-audio nudge

    /// Floated above the pill when the mic is open but no sound is coming
    /// through - almost always the wrong input device. Same black-capsule
    /// chrome as every status pill; the orange mic.slash borrows the error
    /// pill's warning idiom so it reads as "attention", not alarm.
    private var noAudioNudge: some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            Text("No audio detected - check your mic source")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
        }
        .overlayChrome()
    }

    // MARK: - Error

    private func errorPresentation(
        for message: String
    ) -> (symbol: String, tint: Color, title: String, detail: String?) {
        let lowercased = message.lowercased()

        if lowercased.contains("microphone") || lowercased.contains("mic error") {
            let detail = lowercased.contains("did not respond")
                ? "Reconnect it or choose another input"
                : "Check the selected input and try again"
            return ("mic.slash.fill", .orange, "Microphone unavailable", detail)
        }

        if lowercased.contains("no speech") {
            return ("waveform.slash", .orange, "No speech detected", "Try again when you’re ready")
        }

        if lowercased.contains("unsupported language") {
            return ("globe", .orange, "Language not supported", "Pick a language in Settings → Dictation")
        }

        if lowercased.contains("speech engine") || lowercased.contains("model") {
            return ("cpu", .orange, "Speech engine failed", message)
        }

        if lowercased.contains("api key") {
            return ("key.fill", .orange, "API key required", "Add it in Settings to continue")
        }

        return ("exclamationmark", .orange, "Something went wrong", message)
    }

    private func errorView(message: String) -> some View {
        let presentation = errorPresentation(for: message)
        return HStack(spacing: 9) {
            Image(systemName: presentation.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(presentation.tint.opacity(0.92))
                .frame(width: 23, height: 23)
                .background(Circle().fill(presentation.tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)

                if let detail = presentation.detail {
                    Text(detail)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .overlayChrome()
    }
}

// MARK: - Overlay Chrome

/// Shared pill chrome, so every status pill matches: black, full capsule
/// (30pt tall, radius 15), 16pt content row, 11/7 padding, white 0.32
/// hairline.
private extension View {
    func fallbackCardChrome() -> some View {
        self
            .padding(16)
            .frame(width: 340, alignment: .leading)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
    }

    func assistantCardChrome() -> some View {
        self
            .padding(14)
            .frame(width: 360, alignment: .leading)
            .background(
                ZStack {
                    Color.black.opacity(0.94)
                    LinearGradient(
                        colors: [.white.opacity(0.07), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
    }

    func overlayChrome(instruction: Bool = false) -> some View {
        self
            .frame(height: 16)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                Group {
                    if instruction {
                        AnimatedGradientBorder(cornerRadius: 15)
                    } else {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                    }
                }
            )
    }
}

// MARK: - Notch shape + activity motion

/// Reverse-corner notch silhouette used by DynamicNotchKit and Boring Notch.
/// The outer top edge curls inward by a small radius and immediately becomes a
/// vertical body. This creates the characteristic outward-facing top corners
/// without separate tabs or an exaggerated diagonal shoulder.
private struct NativeNotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomRadius) }
        set {
            topCornerRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let topRadius = min(max(topCornerRadius, 0), rect.width * 0.2)
        let bodyLeft = rect.minX + topRadius
        let bodyRight = rect.maxX - topRadius
        let radius = min(
            max(bottomRadius, 0),
            min((bodyRight - bodyLeft) / 2, rect.height - topRadius)
        )

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft, y: rect.minY + topRadius),
            control: CGPoint(x: bodyLeft, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyLeft, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft + radius, y: rect.maxY),
            control: CGPoint(x: bodyLeft, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyRight - radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRight, y: rect.maxY - radius),
            control: CGPoint(x: bodyRight, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyRight, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: bodyRight, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Cumulative fallback lifetime: starts at the upper-left shoulder, descends
/// the left edge, fills across the chin, then climbs the right edge. The path
/// deliberately remains open across the top so completion lands at the upper
/// right rather than drawing behind the physical camera housing.
private struct FallbackPerimeterProgress: Shape {
    var progress: CGFloat
    var topCornerRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                progress,
                AnimatablePair(topCornerRadius, bottomRadius)
            )
        }
        set {
            progress = newValue.first
            topCornerRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let topRadius = min(max(topCornerRadius, 0), rect.width * 0.2)
        let bodyLeft = rect.minX + topRadius
        let bodyRight = rect.maxX - topRadius
        let radius = min(
            max(bottomRadius, 0),
            min((bodyRight - bodyLeft) / 2, rect.height - topRadius)
        )

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft, y: rect.minY + topRadius),
            control: CGPoint(x: bodyLeft, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyLeft, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft + radius, y: rect.maxY),
            control: CGPoint(x: bodyLeft, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyRight - radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRight, y: rect.maxY - radius),
            control: CGPoint(x: bodyRight, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyRight, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: bodyRight, y: rect.minY)
        )
        return path.trimmedPath(from: 0, to: min(max(progress, 0), 1))
    }
}

/// A tiny Apple-style audio meter driven entirely by real microphone history.
/// Each 30 Hz sample enters on the left and advances through five fixed bar
/// positions. Two real samples form each spatial step, slowing the visible
/// travel without inventing motion. Silence returns promptly to five dots.
private struct NotchListeningBars: View {
    let samples: [Float]
    let noAudioDetected: Bool

    private static let barCount = 5
    private static let samplesPerBar = 2

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                let activity = normalizedLevel(at: index)
                let height = 2 + activity * 9

                Capsule(style: .continuous)
                    .fill(
                        noAudioDetected
                            ? Color.orange.opacity(0.68)
                            : Color.white.opacity(0.46 + activity * 0.44)
                    )
                    .frame(width: 2, height: height)
            }
        }
        .frame(width: 18, height: 12, alignment: .center)
        // Slightly overlap neighboring 30 Hz samples to soften vertical steps
        // without adding the delayed, elastic tail of a spring animation.
        .animation(.linear(duration: 0.05), value: samples)
        .animation(.easeInOut(duration: 0.18), value: noAudioDetected)
    }

    private func normalizedLevel(at index: Int) -> CGFloat {
        let start = index * Self.samplesPerBar
        guard start < samples.count else { return 0 }
        let end = min(start + Self.samplesPerBar, samples.count)
        // Keep the leading real sample dominant and lightly blend its neighbor
        // to bridge 30 Hz updates. Using the previous window maximum made
        // adjacent bars lock to the same height during normal speech.
        let leading = CGFloat(max(samples[start], 0))
        let neighbor = start + 1 < end ? CGFloat(max(samples[start + 1], 0)) : leading
        let level = leading * 0.85 + neighbor * 0.15

        // The recorder has already noise-gated and shaped this signal. The old
        // `* 15` mapping saturated at only ~7% input, turning almost every word
        // into five full-height bars. Keep the quiet-speech floor low, but
        // spread the rest over a much wider range so normal speech has shape.
        let floor: CGFloat = 0.012
        let ceiling: CGFloat = 0.68
        guard level > floor else { return 0 }
        let normalized = min(1, (level - floor) / (ceiling - floor))
        return pow(normalized, 0.86)
    }
}

/// Three stationary dots with a gentle luminance handoff. They communicate a
/// short processing pause without text, a spinner, or vertical movement.
private struct NotchProcessingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = t * 2.4 - Double(index) * 0.9
                    let wave = (sin(phase) + 1) / 2
                    Circle()
                        .fill(Color.white.opacity(0.22 + wave * 0.58))
                        .frame(width: 2.5, height: 2.5)
                }
            }
            .frame(width: 14, height: 10, alignment: .center)
        }
    }
}

// MARK: - Typing flow (transcription in flight)

/// Speech-to-text made visible: word-length dashes write themselves
/// out left to right behind a caret, hold for a beat, fade, and start
/// a fresh line. Styled in the waveform's exact idiom - same white,
/// same 3pt stroke (a resting waveform dot, stretched into a word) -
/// and sized to the waveform's line width so the pill barely changes
/// when listening hands over to transcribing.
private struct TypingFlowView: View {
    /// Widths of the ghost words, varied like real text. Sum + gaps ≈
    /// the 13-bar waveform's width (~50pt).
    private static let words: [CGFloat] = [9, 13, 7, 11]
    private static let gap: CGFloat = 4
    /// Cadence between word starts (s). Fast: a warm whisper server
    /// finishes sub-second, and the user should see a COMPLETE line
    /// (~0.35s) within that window, not a half-drawn one.
    private static let perWord: Double = 0.1
    /// How long one word takes to ink out (s).
    private static let writeTime: Double = 0.08
    /// Full line lingers, then fades, then the cycle restarts.
    private static let hold: Double = 0.35
    private static let fade: Double = 0.2

    private static var typingTime: Double {
        Double(words.count - 1) * perWord + writeTime
    }
    private static var cycle: Double { typingTime + hold + fade }
    private static var lineWidth: CGFloat {
        words.reduce(0, +) + gap * CGFloat(words.count - 1)
    }

    /// Anchor for the animation clock. Captured when the view appears so
    /// every new transcription starts at the beginning of the cycle -
    /// clocking off absolute time made fresh pills join mid-cycle,
    /// sometimes right at the fade-out.
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = max(timeline.date.timeIntervalSince(start), 0)
                .truncatingRemainder(dividingBy: Self.cycle)

            ZStack(alignment: .leading) {
                ForEach(Self.words.indices, id: \.self) { i in
                    let p = wordProgress(i, at: t)
                    Capsule()
                        .fill(.white.opacity(0.78))
                        .frame(width: Self.words[i] * p, height: 3)
                        .offset(x: wordStart(i))
                        .opacity(p > 0 ? 1 : 0)
                }

                // Caret - glides along the writing edge, blinks while
                // the finished line holds.
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(caretOpacity(at: t)))
                    .frame(width: 1.5, height: 11)
                    .offset(x: caretX(at: t) + 2)
            }
            .frame(width: Self.lineWidth + 4, height: 16, alignment: .leading)
            .opacity(lineOpacity(at: t))
        }
        .onAppear { start = Date() }
    }

    /// Leading x of word `i` within the line.
    private func wordStart(_ i: Int) -> CGFloat {
        Self.words.prefix(i).reduce(0, +) + Self.gap * CGFloat(i)
    }

    /// 0…1 ink-out progress of word `i`, smoothstep-eased.
    private func wordProgress(_ i: Int, at t: Double) -> CGFloat {
        let raw = (t - Double(i) * Self.perWord) / Self.writeTime
        let clamped = min(max(raw, 0), 1)
        return CGFloat(clamped * clamped * (3 - 2 * clamped))
    }

    private func caretX(at t: Double) -> CGFloat {
        guard t < Self.typingTime else {
            return Self.lineWidth
        }
        let k = min(Int(t / Self.perWord), Self.words.count - 1)
        return wordStart(k) + Self.words[k] * wordProgress(k, at: t)
    }

    private func caretOpacity(at t: Double) -> Double {
        // Solid while writing; soft 0.5s blink once the line is done.
        guard t >= Self.typingTime else { return 0.9 }
        let blink = 0.5 + 0.5 * cos((t - Self.typingTime) * 2 * .pi / 0.5)
        return 0.15 + 0.75 * blink
    }

    private func lineOpacity(at t: Double) -> Double {
        let fadeStart = Self.typingTime + Self.hold
        guard t > fadeStart else { return 1 }
        let raw = min(max((t - fadeStart) / Self.fade, 0), 1)
        return 1 - raw * raw * (3 - 2 * raw)
    }
}

// MARK: - Input Device Picker (inline overlay)

private struct InputDevicePicker: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    var showsHeader: Bool = true
    @State private var hoveredDeviceUID: String?

    /// Sentinel hover key for the "Follow system default" row - no real device
    /// carries this UID.
    private static let followDefaultUID = "__follow_system_default__"

    /// A compact route row modeled after current macOS popovers: the selected
    /// source is a neutral glass tile with a trailing check, never a legacy
    /// radio list or a saturated success color.
    @ViewBuilder
    private func row(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        isSelected: Bool,
        uid: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isSelected ? 0.86 : 0.48))
                    .frame(width: 23, height: 23)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(isSelected ? 0.10 : 0.055))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(isSelected ? 0.92 : 0.66))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.34))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(.white.opacity(0.13)))
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.white.opacity(0.085)
                            : (hoveredDeviceUID == uid ? Color.white.opacity(0.055) : .clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(isSelected ? 0.075 : 0),
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredDeviceUID = hovering ? uid : nil }
        .pointerOnHover()
        .animation(.easeInOut(duration: 0.13), value: hoveredDeviceUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                Text("Input Source")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            if appState.inputDevices.isEmpty {
                Text("No input devices found")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                // "Follow system default" - the un-pinned mode. Selected when
                // no preferred mic is set.
                let followingDefault = !appState.hasPreferredInputDevice
                row(
                    title: "Automatic",
                    subtitle: "Follow system input",
                    symbol: "arrow.triangle.2.circlepath",
                    isSelected: followingDefault,
                    uid: Self.followDefaultUID
                ) {
                    isPresented = false
                    appState.clearPreferredInputDeviceAfterPickerCollapse()
                }

                ForEach(Array(appState.inputDevices.enumerated()), id: \.element.uid) { _, device in
                    // Only the pinned device gets the checkmark. While following
                    // the system default, no single device is singled out.
                    let isPinned = appState.hasPreferredInputDevice
                        && appState.selectedInputDevice?.uid == device.uid
                    row(
                        title: device.name,
                        symbol: "mic.fill",
                        isSelected: isPinned,
                        uid: device.uid
                    ) {
                        isPresented = false
                        appState.selectInputDeviceAfterPickerCollapse(device)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Animated gradient border for instruction mode

private struct AnimatedGradientBorder: View {
    var cornerRadius: CGFloat = 12
    @State private var angle: Double = 0

    private let colors: [Color] = [
        Color(red: 0.85, green: 0.35, blue: 0.65),
        Color(red: 0.75, green: 0.45, blue: 0.9),
        Color(red: 0.45, green: 0.7, blue: 1.0),
        Color(red: 0.4, green: 0.55, blue: 1.0),
        .clear, .clear, .clear, .clear,
        Color(red: 0.85, green: 0.35, blue: 0.65),
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(
                AngularGradient(colors: colors, center: .center, angle: .degrees(angle)),
                lineWidth: 1.5
            )
            .onAppear {
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Glow border with traveling shine for hover states

private struct GlowBorder: View {
    var cornerRadius: CGFloat = 14
    var color: Color
    @State private var appeared = false
    @State private var shineAngle: Double = 0

    var body: some View {
        ZStack {
            // Base border - fades in (strokeBorder stays inside bounds)
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(color.opacity(appeared ? 0.5 : 0), lineWidth: 1.5)

            // Traveling shine highlight (also inside bounds)
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.35),
                            .init(color: color.opacity(appeared ? 0.9 : 0), location: 0.5),
                            .init(color: .clear, location: 0.65),
                            .init(color: .clear, location: 1.0),
                        ],
                        center: .center,
                        angle: .degrees(shineAngle)
                    ),
                    lineWidth: 1.5
                )
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { appeared = true }
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                shineAngle = 360
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Pointer cursor helper

private extension View {
    /// Force the pointing-hand cursor while hovering this view.
    ///
    /// `.onContinuousHover` (not `.onHover`) is essential here:
    /// `.onHover` only fires when hover state *changes*, so after a
    /// click the system can revert the cursor (e.g. macOS resetting to
    /// the view's default after the press) and we never get a chance
    /// to set it back. Continuous hover fires on every mouse movement
    /// inside the view, which means we re-assert the pointing-hand on
    /// every micro-motion and the system can't drift it back to an
    /// I-beam between clicks.
    func pointerOnHover() -> some View {
        self.onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }
}
