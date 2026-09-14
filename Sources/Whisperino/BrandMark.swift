import AppKit
import SwiftUI

/// The family palette - the app icon's colours, and nothing more. The window
/// stays native; these appear in the sidebar badge and as the chart accent.
enum Brand {
    static let bone = Color(red: 0.962, green: 0.950, blue: 0.925)
    static let soot = Color(red: 0.10, green: 0.10, blue: 0.09)
    static let lime = Color(red: 0.72, green: 0.86, blue: 0.30)
    static let limeDeep = Color(red: 0.62, green: 0.78, blue: 0.22)
}

/// The app icon's plate at interface scale: the cursive w on its lime tile.
/// Used once, at the top of the sidebar.
struct BrandBadge: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Brand.lime)
            BrandLine(glyph: .whisperino, color: Brand.soot,
                      lineWidth: size * 0.075, taperTo: BrandGlyph.whisperinoTaper)
                .frame(width: size * 0.74, height: size * 0.52)
                .offset(x: size * 0.04, y: size * 0.03)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The -rino family mark: one unbroken line, drawn with one hand. Each app
/// writes its own glyph with that line; Whisperino's is a cursive w.
///
/// `make-icon.swift` carries a copy of this generator for the app icon - keep
/// the two in step.
struct BrandGlyph {
    /// Whisperino: a cursive w in a 1 × 0.7 box, y down. Round valleys, soft
    /// tops, and the final upstroke carried on up and thinning away - the
    /// whisper.
    static let whisperino = BrandGlyph(segments: [
        Cubic(from: (0.02, 0.20), c1: (0.04, 0.42), c2: (0.09, 0.70), to: (0.17, 0.70)),
        Cubic(from: (0.17, 0.70), c1: (0.25, 0.70), c2: (0.30, 0.32), to: (0.34, 0.24)),
        Cubic(from: (0.34, 0.24), c1: (0.38, 0.16), c2: (0.43, 0.70), to: (0.51, 0.70)),
        Cubic(from: (0.51, 0.70), c1: (0.59, 0.70), c2: (0.64, 0.32), to: (0.68, 0.22)),
        // The tail: on up past the top of the letter, thinning away.
        Cubic(from: (0.68, 0.22), c1: (0.71, 0.13), c2: (0.75, 0.04), to: (0.80, 0.00)),
    ])
    /// Whisperino's line thins to this fraction of its width by the end.
    static let whisperinoTaper: CGFloat = 0.24

    struct Cubic {
        let p0, p1, p2, p3: CGPoint
        init(from a: (CGFloat, CGFloat), c1: (CGFloat, CGFloat),
             c2: (CGFloat, CGFloat), to b: (CGFloat, CGFloat)) {
            p0 = CGPoint(x: a.0, y: a.1); p1 = CGPoint(x: c1.0, y: c1.1)
            p2 = CGPoint(x: c2.0, y: c2.1); p3 = CGPoint(x: b.0, y: b.1)
        }
        func point(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                           y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
        }
    }

    let segments: [Cubic]
    private static let samplesPerSegment = 64

    struct Geometry {
        let path: Path
        let length: CGFloat
    }

    func geometry(in rect: CGRect) -> Geometry {
        var raw: [CGPoint] = []
        for (index, segment) in segments.enumerated() {
            let start = index == 0 ? 0 : 1
            for i in start...Self.samplesPerSegment {
                raw.append(segment.point(CGFloat(i) / CGFloat(Self.samplesPerSegment)))
            }
        }

        let minX = raw.map(\.x).min()!, maxX = raw.map(\.x).max()!
        let minY = raw.map(\.y).min()!, maxY = raw.map(\.y).max()!
        let scale = min(rect.width / (maxX - minX), rect.height / (maxY - minY))
        let ox = rect.midX - (minX + maxX) / 2 * scale
        let oy = rect.midY - (minY + maxY) / 2 * scale
        let pts = raw.map { CGPoint(x: ox + $0.x * scale, y: oy + $0.y * scale) }

        // Cumulative arc length, so trim parameters map onto real distance.
        var cumulative: [CGFloat] = [0]
        for i in 1..<pts.count {
            cumulative.append(cumulative[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
        }
        let length = cumulative.last!

        var path = Path()
        path.move(to: pts[0])
        for pt in pts.dropFirst() { path.addLine(to: pt) }

        return Geometry(path: path, length: length)
    }
}

/// Draws a `BrandGlyph` as one round-capped stroke.
///
/// `taperTo` is the stroke width at the end of the line as a fraction of
/// `lineWidth`. Whisperino's line thins away to almost nothing: a whisper is
/// sound trailing off.
struct BrandLine: View {
    var glyph = BrandGlyph.whisperino
    var color: Color
    var lineWidth: CGFloat
    var taperTo: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let geometry = glyph.geometry(in: CGRect(origin: .zero, size: size))
            func width(at t: CGFloat) -> CGFloat {
                // Hold full weight through the letter; let go only on the
                // final upstroke.
                let start: CGFloat = 0.78
                let eased = t <= start ? 0 : pow((t - start) / (1 - start), 1.6)
                return lineWidth * (1 - (1 - taperTo) * eased)
            }
            // A tapered stroke drawn as short overlapping round-capped
            // segments; a filled outline would be exact, this is invisible.
            let segments = 220
            for i in 0..<segments {
                let from = CGFloat(i) / CGFloat(segments)
                let to = CGFloat(i + 1) / CGFloat(segments)
                let w = width(at: (from + to) / 2)
                context.stroke(geometry.path.trimmedPath(from: from, to: to),
                               with: .color(color),
                               style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
        }
    }
}
