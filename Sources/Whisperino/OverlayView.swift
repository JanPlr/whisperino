import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState

    private var isDismissing: Bool {
        if case .dismissing = appState.state { return true }
        return false
    }

    /// Extra height for attachment rows + add-more button
    private var attachmentExtraHeight: CGFloat {
        let count = appState.attachedContexts.count
        guard count > 0 else { return 0 }
        let rows = CGFloat(min(count, AppState.maxAttachments)) * 32
        let addButton: CGFloat = count < AppState.maxAttachments ? 36 : 0
        return rows + addButton
    }

    var body: some View {
        Group {
            switch appState.state {
            case .idle:
                Color.clear.frame(width: 0, height: 0)
            case .recording, .paused:
                recordingView
            case .transcribing:
                transcribingView.padding(.top, 6)
            case .refining:
                refiningView.padding(.top, 6)
            case .result, .dismissing:
                resultDismissView.padding(.top, 6)
            case .error(let message):
                errorView(message: message).padding(.top, 6)
            }
        }
        .frame(width: 380)
        .padding(.top, 90)
        .frame(height: 180 + attachmentExtraHeight, alignment: .top)
        .animation(appState.suppressStateAnimation ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: appState.state)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.attachedContexts.count)
    }

    @State private var isHoveringPill = false
    @State private var isHoveringCancel = false

    // MARK: - Recording

    private var recordingView: some View {
        let hasAttachments = appState.isInstructionMode && !appState.attachedContexts.isEmpty

        return ZStack(alignment: .topTrailing) {
            // Main pill — click anywhere to stop recording
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    // Invisible counterweight to balance the paperclip on the right
                    if hasAttachments {
                        Spacer(minLength: 0)
                        Color.clear.frame(width: 20, height: 1)
                    }

                    HStack(spacing: 3) {
                        ForEach(0..<9, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(.white.opacity(0.7))
                                .frame(width: 4, height: barHeight(for: i))
                        }
                    }
                    .frame(height: 20)

                    if appState.isInstructionMode {
                        clipboardButton
                    }

                    if hasAttachments { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Attachment list — expands the pill downward
                if hasAttachments {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 8)

                    VStack(spacing: 2) {
                        ForEach(appState.attachedContexts) { ctx in
                            attachmentRow(ctx)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // "+ Add more" button
                        if appState.attachedContexts.count < AppState.maxAttachments {
                            addMoreButton
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            .frame(width: hasAttachments ? 300 : nil)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                Group {
                    if isHoveringCancel {
                        GlowBorder(cornerRadius: 14, color: Color(red: 0.9, green: 0.25, blue: 0.25))
                    } else if isHoveringPill {
                        GlowBorder(cornerRadius: 14, color: Color(red: 0.25, green: 0.78, blue: 0.45))
                    } else if appState.isInstructionMode {
                        AnimatedGradientBorder(cornerRadius: 14)
                    } else {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { appState.toggleRecording() }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAttachments)

            // Cancel X — positioned outside pill corner via alignment guides
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(isHoveringCancel ? 1 : 0.85))
                .frame(width: 16, height: 16)
                .background(
                    Circle().fill(
                        isHoveringCancel
                            ? Color(red: 0.8, green: 0.2, blue: 0.2)
                            : Color(white: 0.3)
                    )
                )
                .clipShape(Circle())
                .contentShape(Circle().scale(1.5))
                .onHover { isHoveringCancel = $0 }
                .onTapGesture { appState.cancelRecording() }
                .opacity(isHoveringPill ? (isHoveringCancel ? 1 : 0.7) : 0)
                .scaleEffect(isHoveringPill ? 1 : 0.4)
                .alignmentGuide(.trailing) { d in d[.trailing] - 6 }
                .alignmentGuide(.top) { d in d[.top] + 6 }
                .animation(.easeOut(duration: 0.15), value: isHoveringPill)
                .animation(.easeInOut(duration: 0.1), value: isHoveringCancel)
        }
        .onHover { isHoveringPill = $0 }
        .animation(.easeOut(duration: 0.06), value: appState.audioLevel)
        .animation(.easeInOut(duration: 0.2), value: isHoveringPill)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.attachedContexts.count)
    }

    private func attachmentRow(_ ctx: AttachedContext) -> some View {
        AttachmentRowView(ctx: ctx, onRemove: { appState.removeAttachment(id: ctx.id) })
    }

    private var clipboardButton: some View {
        let hasAttachments = !appState.attachedContexts.isEmpty
        return Image(systemName: "paperclip")
            .font(.system(size: 11, weight: hasAttachments ? .semibold : .regular))
            .foregroundStyle(.white.opacity(hasAttachments ? 0.75 : 0.35))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .onTapGesture { appState.addClipboardAttachment() }
    }

    @State private var isHoveringAddMore = false

    private var addMoreButton: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .medium))
                Text("Add more clipboard content")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.white.opacity(isHoveringAddMore ? 0.6 : 0.3))

            Text("Copy more context or images to your clipboard and add them here")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(isHoveringAddMore ? 0.35 : 0.18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHoveringAddMore = $0 }
        .onTapGesture { appState.addClipboardAttachment() }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(appState.audioLevel)
        let patterns: [CGFloat] = [0.2, 0.45, 0.75, 0.95, 1.0, 0.9, 0.65, 0.4, 0.15]
        let barLevel = level * patterns[index]
        return max(3, barLevel * 20)
    }

    // MARK: - Transcribing

    private var transcribingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text("Transcribing…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .overlayChrome()
    }

    // MARK: - Refining / Generating

    private var refiningView: some View {
        HStack(spacing: 8) {
            if appState.isAgentMode {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Text(appState.agentStatus ?? "Working\u{2026}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.25), value: appState.agentStatus)
            } else if appState.isInstructionMode {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Generating\u{2026}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Refining\u{2026}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .overlayChrome(instruction: appState.isInstructionMode || appState.isAgentMode)
    }

    // MARK: - Result / Dismissing

    private var resultDismissView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)

            Text(appState.isInstructionMode ? "Generated" : "Copied to clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .overlayChrome()
        .scaleEffect(isDismissing ? 0.95 : 1.0)
        .opacity(isDismissing ? 0 : 1.0)
        .animation(.easeOut(duration: 0.3), value: isDismissing)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .overlayChrome()
    }
}

// MARK: - Overlay Chrome

private extension View {
    func overlayChrome(instruction: Bool = false) -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                Group {
                    if instruction {
                        AnimatedGradientBorder(cornerRadius: 14)
                    } else {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
                }
            )
    }
}

// MARK: - Attachment row with image preview

private struct AttachmentRowView: View {
    let ctx: AttachedContext
    let onRemove: () -> Void
    @State private var showingPreview = false

    var body: some View {
        HStack(spacing: 6) {
            // Thumbnail or text icon
            if case .image(let image) = ctx.content {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white.opacity(showingPreview ? 0.4 : 0.15), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { showingPreview.toggle() }
                    .popover(isPresented: $showingPreview, arrowEdge: .top) {
                        imagePreview(image)
                    }
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 24, height: 24)
            }

            Text(ctx.preview)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Remove button
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { onRemove() }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private func imagePreview(_ image: NSImage) -> some View {
        let maxWidth: CGFloat = 520
        let maxHeight: CGFloat = 400
        let aspect = image.size.width / max(image.size.height, 1)
        let width = min(maxWidth, maxHeight * aspect)
        let height = min(maxHeight, maxWidth / aspect)

        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(8)
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
            // Base border — fades in (strokeBorder stays inside bounds)
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
