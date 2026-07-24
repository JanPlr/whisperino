import SwiftUI

/// Rafterino mode - the Team Rafterino easter egg, born at the 2026 offsite
/// raft build. When enabled, the overlay pill goes to sea: the waveform takes
/// an ocean tint, the hairline border becomes slow-moving water, and the
/// transcription animation is a little raft sailing under the team flag.
/// Everything keeps the pill's exact geometry (full capsule, 30pt, radius 15)
/// - only the paint changes.
enum Rafterino {
    /// The flag's field blue - the hand-painted ultramarine from the towel.
    static let field = Color(red: 0.10, green: 0.26, blue: 0.72)
    /// "RAFTERINO" lettering red.
    static let lettering = Color(red: 0.78, green: 0.16, blue: 0.13)
    /// Water/foam accent that reads on the black pill.
    static let foam = Color(red: 0.45, green: 0.75, blue: 1.0)

    /// Draws the little raft - lashed-log deck, mast, skull flag - with its
    /// waterline at the context's origin. ~14pt wide, 11pt of mast+flag
    /// above the water. Shared by the sailing (transcription) and live-wave
    /// (recording) views; transform the context first to place/tilt/scale.
    static func drawRaft(_ raft: inout GraphicsContext) {
        let wood = Color.white.opacity(0.85)
        // Deck of lashed logs (seams hinted by two gaps).
        raft.fill(Path(roundedRect: CGRect(x: -7, y: -3, width: 14, height: 3), cornerRadius: 1.5), with: .color(wood))
        for seamX in [-2.6, 2.0] {
            raft.fill(Path(CGRect(x: seamX, y: -2.6, width: 0.7, height: 2.2)), with: .color(.black.opacity(0.5)))
        }
        // Mast + the team flag, skull reduced to its white dot - all a
        // 4pt flag can honestly carry.
        raft.fill(Path(CGRect(x: -0.6, y: -10.5, width: 1.2, height: 8)), with: .color(wood))
        raft.fill(Path(roundedRect: CGRect(x: 0.6, y: -11, width: 6.2, height: 4.4), cornerRadius: 1), with: .color(Color(red: 0.22, green: 0.45, blue: 0.95)))
        raft.fill(Ellipse().path(in: CGRect(x: 2.9, y: -9.7, width: 1.7, height: 1.7)), with: .color(.white))
    }

    /// A message in a bottle, lying on its side with the cork to the right,
    /// waterline at the context's origin. ~13pt wide, low profile - a bottle
    /// floats mostly IN the water, unlike the raft's mast.
    static func drawBottle(_ ctx: inout GraphicsContext) {
        let glass = Color(red: 0.72, green: 0.93, blue: 1.0).opacity(0.5)
        // Body + neck in translucent glass, so the water line reads
        // through it.
        ctx.fill(Path(roundedRect: CGRect(x: -5.5, y: -4.2, width: 9, height: 4.4), cornerRadius: 2.1), with: .color(glass))
        ctx.fill(Path(roundedRect: CGRect(x: 3.2, y: -3.0, width: 2.6, height: 2.0), cornerRadius: 0.8), with: .color(glass))
        // Cork.
        ctx.fill(Path(roundedRect: CGRect(x: 5.6, y: -3.1, width: 1.7, height: 2.2), cornerRadius: 0.5), with: .color(Color(red: 0.82, green: 0.62, blue: 0.38).opacity(0.95)))
        // The rolled-up message - solid white so it's clearly *your words*
        // inside the glass.
        ctx.fill(Path(roundedRect: CGRect(x: -4.0, y: -3.3, width: 4.2, height: 2.4), cornerRadius: 1.1), with: .color(.white.opacity(0.85)))
    }
}

// MARK: - Skull & crossbones mark

/// The Rafterino skull & crossbones, redrawn from the flag in a 100×100
/// design space. Stencil-style square eyes/nose to match the painted
/// original. `field` is the color painted into the eyes and nose; pass
/// `nil` to punch them out instead (for template icons - the menu bar -
/// where whatever is behind must show through).
struct RafterinoSkull: View {
    var bone: Color = .white
    var field: Color? = Rafterino.field

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            ctx.translateBy(
                x: (size.width - 100 * s) / 2,
                y: (size.height - 100 * s) / 2
            )
            ctx.scaleBy(x: s, y: s)

            // Crossed bones behind the skull - a capsule shaft with the
            // classic double knob on each end.
            for angle in [45.0, -45.0] {
                var b = ctx
                b.translateBy(x: 50, y: 54)
                b.rotate(by: .degrees(angle))
                b.fill(
                    Capsule().path(in: CGRect(x: -42, y: -5, width: 84, height: 10)),
                    with: .color(bone)
                )
                for endX in [-42.0, 42.0] {
                    b.fill(Ellipse().path(in: CGRect(x: endX - 6.5, y: -10.5, width: 13, height: 13)), with: .color(bone))
                    b.fill(Ellipse().path(in: CGRect(x: endX - 6.5, y: -2.5, width: 13, height: 13)), with: .color(bone))
                }
            }

            // Cranium + jaw, with the flag's gap between them (the bones
            // show through - just like the towel).
            ctx.fill(Ellipse().path(in: CGRect(x: 24, y: 12, width: 52, height: 50)), with: .color(bone))
            ctx.fill(Path(roundedRect: CGRect(x: 39, y: 65, width: 22, height: 14), cornerRadius: 4), with: .color(bone))

            // Stencil eyes + nose - painted in the field color, or erased
            // right through the artwork when there is no field.
            var features = ctx
            if field == nil { features.blendMode = .destinationOut }
            let paint = field ?? .black
            features.fill(Path(roundedRect: CGRect(x: 33, y: 28, width: 11, height: 13), cornerRadius: 3), with: .color(paint))
            features.fill(Path(roundedRect: CGRect(x: 56, y: 28, width: 11, height: 13), cornerRadius: 3), with: .color(paint))
            features.fill(Path(roundedRect: CGRect(x: 46, y: 47, width: 8, height: 9), cornerRadius: 2.5), with: .color(paint))
        }
    }
}

// MARK: - Raft mark (the friendly logo)

/// The raft as an icon: deck of lashed logs, mast, pennant. This is the
/// mark that replaces the waveform logo while the flag is hoisted - the
/// skull stayed on the flag artwork, but as an everyday icon it scared
/// the crew. One color, and the log gaps are real gaps, so it works as
/// a menu bar template with no punch-out tricks.
struct RafterinoRaftMark: View {
    var color: Color = .white

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            ctx.translateBy(
                x: (size.width - 100 * s) / 2,
                y: (size.height - 100 * s) / 2
            )
            ctx.scaleBy(x: s, y: s)

            // Deck: one wide slab - at icon sizes separate logs collapse
            // into dots, so the raft-ness comes from the deck's width and
            // the two punched lashing seams instead.
            ctx.fill(Path(roundedRect: CGRect(x: 4, y: 64, width: 92, height: 16), cornerRadius: 8), with: .color(color))
            var seams = ctx
            seams.blendMode = .destinationOut
            for seamX in [33.0, 62.0] {
                seams.fill(Path(roundedRect: CGRect(x: seamX, y: 63, width: 5, height: 18), cornerRadius: 2.5), with: .color(.black))
            }
            // Mast.
            ctx.fill(Path(roundedRect: CGRect(x: 46, y: 18, width: 8, height: 50), cornerRadius: 4), with: .color(color))
            // Pennant, flying to the right.
            ctx.fill(Path(roundedRect: CGRect(x: 53, y: 20, width: 33, height: 21), cornerRadius: 5), with: .color(color))
        }
    }
}

// MARK: - The full flag

/// The Rafterino banner as hung between the raft's builders: white flag,
/// blue field with the skull, red "RAFTERINO" below. Sized by its frame
/// width; height follows.
struct RafterinoFlag: View {
    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Rafterino.field)
                RafterinoSkull()
                    .padding(5)
            }
            .aspectRatio(0.76, contentMode: .fit)

            Text("RAFTERINO")
                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                .kerning(0.6)
                .foregroundStyle(Rafterino.lettering)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Water border

/// The Rafterino counterpart to `AnimatedGradientBorder`: the same slowly
/// rotating angular gradient, but in water blues instead of the AI rainbow.
/// Replaces the white hairline while the mode is on.
struct RafterinoWaterBorder: View {
    var cornerRadius: CGFloat = 15
    @State private var angle: Double = 0

    private let colors: [Color] = [
        Color(red: 0.15, green: 0.35, blue: 0.85),
        Color(red: 0.30, green: 0.65, blue: 1.00),
        Color(red: 0.55, green: 0.90, blue: 1.00),
        Color(red: 0.25, green: 0.55, blue: 0.95),
        Color(red: 0.10, green: 0.25, blue: 0.70),
        Color(red: 0.15, green: 0.35, blue: 0.85),
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(
                AngularGradient(colors: colors, center: .center, angle: .degrees(angle)),
                lineWidth: 1.5
            )
            .onAppear {
                withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Live wave (recording - the raft rides your voice)

/// Rafterino's recording view: the audio waveform rendered as a water
/// surface instead of bars - your voice IS the swell - with the raft
/// riding it in place, climbing and tilting as you speak. Same 16pt row
/// as the bar waveform; the canvas carries flag headroom like RaftFlowView.
struct RafterinoLiveWaveView: View {
    /// Live level buffer from AppState (rolls right-to-left).
    var samples: [Float]

    private static let width: CGFloat = 56
    private static let canvasHeight: CGFloat = 30
    /// One full out-and-back cruise (s). Slow - the raft is under sail
    /// for the whole take, so it should amble, not race.
    private static let sailTime: Double = 11.0

    /// Per-frame eased copy of the sample buffer - the Canvas equivalent
    /// of the bars' 0.04s animation. A reference type on purpose:
    /// TimelineView drives the redraws, so mutating this mustn't
    /// invalidate the view.
    private final class Smoother {
        var display = [Double](repeating: 0, count: AppState.waveformBarCount)
        var lastTick = Date()
    }
    @State private var smoother = Smoother()
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = max(timeline.date.timeIntervalSince(start), 0)

                // Ease displayed levels toward the live samples
                // (exponential, framerate-independent).
                let dt = min(max(timeline.date.timeIntervalSince(smoother.lastTick), 0), 0.1)
                smoother.lastTick = timeline.date
                let k = 1 - exp(-dt * 16)
                for i in smoother.display.indices {
                    let target = i < samples.count ? Double(samples[i]) : 0
                    smoother.display[i] += (target - smoother.display[i]) * k
                }

                let bottom = size.height
                // Swell height per sample column - the bars' exact recipe
                // ([1,2,1] smoothing + pow boost), scaled to 3…10 so the
                // flag stays inside the pill at full shout.
                func level(_ i: Int) -> CGFloat {
                    let d = smoother.display
                    let curr = d[i]
                    let prev = i > 0 ? d[i - 1] : curr
                    let next = i < d.count - 1 ? d[i + 1] : curr
                    let smoothed = (prev + curr * 2 + next) / 4
                    return 3 + CGFloat(pow(smoothed, 0.6)) * 7
                }
                // Continuous surface: cosine-interpolate between sample
                // columns. The travelling ripple is gated by the live level:
                // a silent mic must read as a dead-flat waterline (that's
                // the "is audio coming through?" signal), so the water only
                // rolls while something is actually being heard.
                let activity = smoother.display.max() ?? 0
                let rippleGain = CGFloat(min(1, activity * 10))
                func surfaceY(_ x: CGFloat) -> CGFloat {
                    let pos = max(0, min(1, x / size.width)) * CGFloat(smoother.display.count - 1)
                    let i = min(Int(pos), smoother.display.count - 2)
                    let f = pos - CGFloat(i)
                    let w = (1 - cos(f * .pi)) / 2
                    let h = level(i) * (1 - w) + level(i + 1) * w
                    let ripple = rippleGain * (0.7 * sin(x / 6.5 - t * 2.8) + 0.35 * sin(x / 3.4 + t * 1.9))
                    return bottom - 2 - h + ripple
                }

                // Surface line, then a faint body of water beneath it.
                var line = Path()
                line.move(to: CGPoint(x: 0, y: surfaceY(0)))
                for x in stride(from: CGFloat(1.5), through: size.width, by: 1.5) {
                    line.addLine(to: CGPoint(x: x, y: surfaceY(x)))
                }
                var water = line
                water.addLine(to: CGPoint(x: size.width, y: bottom))
                water.addLine(to: CGPoint(x: 0, y: bottom))
                water.closeSubpath()
                ctx.fill(
                    water,
                    with: .linearGradient(
                        Gradient(colors: [Rafterino.foam.opacity(0.20), Rafterino.foam.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: bottom - 14),
                        endPoint: CGPoint(x: 0, y: bottom)
                    )
                )
                ctx.stroke(
                    line,
                    with: .linearGradient(
                        Gradient(colors: [
                            Rafterino.foam.opacity(0.25),
                            Rafterino.foam.opacity(0.85),
                            Rafterino.foam.opacity(0.25),
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    ),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )

                // The raft, under sail for as long as you talk, riding
                // whatever swell your voice throws under it. It cruises
                // back and forth INSIDE the pill - a cosine path, so it
                // eases into each turn instead of hitting a wall - and
                // never leaves the frame. Slightly scaled down so mast +
                // flag clear the pill even on the tallest wave; tilt
                // follows the local slope, damped - a raft is heavy.
                let margin: CGFloat = 10
                let sweep = 0.5 - 0.5 * cos(2 * .pi * t / Self.sailTime)
                let x = margin + (size.width - 2 * margin) * (1 - CGFloat(sweep))
                let slope = (surfaceY(x + 3) - surfaceY(x - 3)) / 6
                var raft = ctx
                raft.translateBy(x: x, y: surfaceY(x) - 1)
                raft.rotate(by: .radians(Double(atan(slope)) * 0.7))
                raft.scaleBy(x: 0.85, y: 0.85)
                Rafterino.drawRaft(&raft)
            }
            .frame(width: Self.width, height: Self.canvasHeight)
            .frame(height: 16, alignment: .bottom)
        }
        .onAppear {
            start = Date()
            smoother.lastTick = Date()
        }
    }
}

// MARK: - Bottle flow (transcription in flight - your message at sea)

/// Rafterino's answer to `TypingFlowView`: while whisper works, your words
/// are literally a message in a bottle - a corked bottle drifting across
/// the pill with the current (right to left, same direction the sea moves),
/// rocking on the water. Distinct from the raft, which stars while you
/// record. Same 16pt row and roughly the waveform's width, so the pill
/// morph stays identical.
struct RafterinoBottleFlowView: View {
    private static let width: CGFloat = 68
    /// One full drift across (s). Fast enough that a sub-second
    /// transcription still shows real travel.
    private static let sailTime: Double = 4.0

    /// Animation clock anchor - captured on appear so every fresh pill
    /// starts with the raft entering from the left, not mid-ocean.
    @State private var start = Date()

    /// Canvas height. Taller than the 16pt content row so nothing clips
    /// at a wave crest - the extra headroom rides in the pill's own
    /// vertical padding (SwiftUI frames don't clip; only the pill capsule
    /// does, 7pt further out).
    private static let canvasHeight: CGFloat = 30

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = max(timeline.date.timeIntervalSince(start), 0)
            Canvas { ctx, size in
                // Two layered sines - a swell and a ripple - so the water
                // rolls instead of ticking. Phase moves left: the water
                // flows against the raft's course. Baseline sits where the
                // old 16pt row's y=11.5 was (canvas is bottom-aligned).
                func waveY(_ x: CGFloat) -> CGFloat {
                    (Self.canvasHeight - 4.5)
                        + 1.8 * sin(x / 11 - t * 2.4)
                        + 0.6 * sin(x / 5.3 + t * 1.6)
                }

                // The water line, faded toward both edges like the
                // waveform's shape mask.
                var wave = Path()
                wave.move(to: CGPoint(x: 0, y: waveY(0)))
                for x in stride(from: CGFloat(1.5), through: size.width, by: 1.5) {
                    wave.addLine(to: CGPoint(x: x, y: waveY(x)))
                }
                ctx.stroke(
                    wave,
                    with: .linearGradient(
                        Gradient(colors: [
                            Rafterino.foam.opacity(0.25),
                            Rafterino.foam.opacity(0.85),
                            Rafterino.foam.opacity(0.25),
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    ),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )

                // Bottle position: enters off the right edge, drifts out
                // the left - a bottle has no sail, it can only go with
                // the current. Rocks with the local slope plus its own
                // gentle roll (glass is round; it rocks more than a raft).
                let progress = t.truncatingRemainder(dividingBy: Self.sailTime) / Self.sailTime
                let x = size.width + 10 - CGFloat(progress) * (size.width + 20)
                let slope = (waveY(x + 3) - waveY(x - 3)) / 6
                // Fade in/out at the edges so the bottle never pops or clips.
                let edgeFade = min(1, max(0, (x + 8) / 12), max(0, (size.width + 8 - x) / 12))

                var bottle = ctx
                bottle.opacity = Double(edgeFade)
                bottle.translateBy(x: x, y: waveY(x) - 0.5)
                bottle.rotate(by: .radians(Double(atan(slope)) * 0.7 + 0.13 * sin(t * 2.3)))
                Rafterino.drawBottle(&bottle)
            }
            .frame(width: Self.width, height: Self.canvasHeight)
            .frame(height: 16, alignment: .bottom)
        }
        .onAppear { start = Date() }
    }
}
