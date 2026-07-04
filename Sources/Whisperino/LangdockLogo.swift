import SwiftUI

/// The official Langdock mark, traced 1:1 from the brand SVG (57×94 viewBox)
/// so it scales crisply to any size and takes any tint. Monochrome by default
/// to sit quietly next to native icons; pass a color to tint it (or
/// `LangdockMark.brand` for the original navy).
struct LangdockMark: View {
    var color: Color = .primary

    /// The logo's original brand color (#131A34).
    static let brand = Color(red: 0x13 / 255, green: 0x1A / 255, blue: 0x34 / 255)

    var body: some View {
        LangdockMarkShape().fill(color)
    }
}

/// The raw vector outline, mapped from the 57×94 source viewBox into any rect
/// (aspect-fit, centered).
private struct LangdockMarkShape: Shape {
    // Native artboard from the source SVG.
    private static let artboard = CGSize(width: 57, height: 94)

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 55.8605, y: 63.2287))
        p.addCurve(to: CGPoint(x: 55.8437, y: 57.2992),
                   control1: CGPoint(x: 56.9307, y: 61.3952),
                   control2: CGPoint(x: 56.9249, y: 59.1264))
        p.addLine(to: CGPoint(x: 38.2244, y: 27.5353))
        p.addLine(to: CGPoint(x: 23.5019, y: 2.84763))
        p.addCurve(to: CGPoint(x: 13.4526, y: 2.87609),
                   control1: CGPoint(x: 21.2284, y: -0.964646),
                   control2: CGPoint(x: 15.7043, y: -0.949056))
        p.addLine(to: CGPoint(x: 0.808273, y: 24.3536))
        p.addCurve(to: CGPoint(x: 0.808273, y: 30.287),
                   control1: CGPoint(x: -0.269424, y: 26.1844),
                   control2: CGPoint(x: -0.269424, y: 28.4563))
        p.addLine(to: CGPoint(x: 16.7114, y: 57.3004))
        p.addCurve(to: CGPoint(x: 16.7184, y: 63.2216),
                   control1: CGPoint(x: 17.7868, y: 59.1264),
                   control2: CGPoint(x: 17.7895, y: 61.3925))
        p.addLine(to: CGPoint(x: 4.19376, y: 84.6134))
        p.addCurve(to: CGPoint(x: 9.23418, y: 93.4124),
                   control1: CGPoint(x: 1.91248, y: 88.5095),
                   control2: CGPoint(x: 4.72072, y: 93.4124))
        p.addLine(to: CGPoint(x: 34.8728, y: 93.4124))
        p.addCurve(to: CGPoint(x: 39.9156, y: 90.5172),
                   control1: CGPoint(x: 36.9483, y: 93.4124),
                   control2: CGPoint(x: 38.8683, y: 92.3105))
        p.addLine(to: CGPoint(x: 55.8605, y: 63.2287))
        p.closeSubpath()

        let vb = Self.artboard
        let scale = min(rect.width / vb.width, rect.height / vb.height)
        let dx = rect.minX + (rect.width - vb.width * scale) / 2
        let dy = rect.minY + (rect.height - vb.height * scale) / 2
        return p.applying(
            CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        )
    }
}
