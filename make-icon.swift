#!/usr/bin/env swift
//
// Draws AppIcon.icns from scratch, so the mark stays editable instead of
// living as an opaque binary.
//
//   ./make-icon.swift                    # regenerate AppIcon.icns in place
//   ./make-icon.swift out.icns           # write somewhere else
//   ./make-icon.swift --preview out.png  # contact sheet: treatments, Dock, sizes
//
// The mark is the -rino family line: one unbroken stroke.
// Same hand in every app; Whisperino writes a cursive w with it. The generator is a copy of Sources/Whisperino/BrandMark.swift
// - keep the two in step.

import AppKit
import Foundation
import SwiftUI

// MARK: - Palette

let bone = Color(red: 0.962, green: 0.950, blue: 0.925)
let soot = Color(red: 0.10, green: 0.10, blue: 0.09)
/// Whisperino's colour in the family.
let lime = Color(red: 0.72, green: 0.86, blue: 0.30)
let limeDeep = Color(red: 0.62, green: 0.78, blue: 0.22)

/// Apple's rounded-rect corner for a full-bleed icon canvas.
let cornerFraction: CGFloat = 0.2246

// MARK: - The line (copy of BrandMark.swift)

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

// MARK: - Treatments

enum Treatment: String, CaseIterable {
    /// Ink line over a soft tinted plate on bone.
    case plate
    /// Two lines, same hand: the colour ghosted behind the ink.
    case ghost
    /// One big gesture on the colour field, cropped by the tile.
    case gesture
}

/// Which treatment ships. Change here, run the script, done.
let shipping: Treatment = .plate

struct AppIconArtwork: View {
    let size: CGFloat
    var treatment: Treatment = shipping

    var body: some View {
        ZStack {
            switch treatment {
            case .plate:
                RoundedRectangle(cornerRadius: size * cornerFraction, style: .continuous)
                    .fill(bone)
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .fill(lime.opacity(0.6))
                    .frame(width: size * 0.56, height: size * 0.56)
                    .offset(x: -size * 0.06, y: -size * 0.06)
                BrandLine(glyph: .whisperino, color: soot, lineWidth: size * 0.054, taperTo: BrandGlyph.whisperinoTaper)
                    .frame(width: size * 0.64, height: size * 0.46)
                    .offset(x: size * 0.04, y: size * 0.04)

            case .ghost:
                RoundedRectangle(cornerRadius: size * cornerFraction, style: .continuous)
                    .fill(bone)
                BrandLine(glyph: .whisperino, color: lime.opacity(0.8), lineWidth: size * 0.054, taperTo: BrandGlyph.whisperinoTaper)
                    .frame(width: size * 0.64, height: size * 0.46)
                    .offset(x: -size * 0.055, y: -size * 0.055)
                BrandLine(glyph: .whisperino, color: soot, lineWidth: size * 0.054, taperTo: BrandGlyph.whisperinoTaper)
                    .frame(width: size * 0.64, height: size * 0.46)
                    .offset(x: size * 0.03, y: size * 0.03)

            case .gesture:
                RoundedRectangle(cornerRadius: size * cornerFraction, style: .continuous)
                    .fill(LinearGradient(colors: [lime, limeDeep],
                                         startPoint: .top, endPoint: .bottom))
                BrandLine(glyph: .whisperino, color: soot, lineWidth: size * 0.085, taperTo: BrandGlyph.whisperinoTaper)
                    .frame(width: size * 1.02, height: size * 0.72)
                    .offset(x: -size * 0.02, y: size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * cornerFraction, style: .continuous))
    }
}

// MARK: - Contact sheet

/// How the icon actually gets seen: the three treatments, then the shipping
/// one in a Dock row and at the small sizes Finder and the switcher use.
struct ContactSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("whisperino · the family line")
                .font(.system(size: 18, weight: .semibold))

            HStack(alignment: .top, spacing: 22) {
                ForEach(Treatment.allCases, id: \.self) { t in
                    VStack(spacing: 8) {
                        AppIconArtwork(size: 168, treatment: t)
                        Text(t == shipping ? "\(t.rawValue) · shipping" : t.rawValue)
                            .font(.system(size: 12, weight: t == shipping ? .semibold : .regular))
                            .foregroundStyle(t == shipping ? .primary : .secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("in the Dock").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    dockNeighbour(Color(red: 0.36, green: 0.61, blue: 0.96), "safari")
                    dockNeighbour(Color(red: 0.95, green: 0.95, blue: 0.95), "notes", dark: true)
                    AppIconArtwork(size: 64)
                    dockNeighbour(Color(red: 0.16, green: 0.16, blue: 0.17), "terminal")
                    dockNeighbour(Color(red: 0.94, green: 0.36, blue: 0.34), "music")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.45)))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("small").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach([16, 32, 64, 128] as [CGFloat], id: \.self) { s in
                        VStack(spacing: 6) {
                            AppIconArtwork(size: s)
                            Text("\(Int(s))").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.black)
        .padding(30)
        .background(Color(white: 0.92))
    }

    func dockNeighbour(_ color: Color, _ name: String, dark: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 64 * cornerFraction, style: .continuous)
            .fill(color)
            .frame(width: 64, height: 64)
            .overlay(Circle().fill(dark ? .black.opacity(0.15) : .white.opacity(0.35))
                .frame(width: 26, height: 26))
    }
}

// MARK: - Output

let args = CommandLine.arguments

if args.count > 2, args[1] == "--preview" {
    MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: ContactSheet())
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { exit(1) }
        try! data.write(to: URL(fileURLWithPath: args[2]))
        print("Wrote \(args[2])")
    }
    exit(0)
}

let outputPath = args.count > 1 ? args[1] : "AppIcon.icns"
let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Whisperino-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

MainActor.assumeIsolated {
    for variant in variants {
        // Render at 4x and downsample; the rasterizer is far kinder to the
        // line's edges that way than drawing 16pt artwork directly.
        let renderer = ImageRenderer(content: AppIconArtwork(size: variant.pixels))
        renderer.scale = 4
        renderer.isOpaque = false
        guard let oversampled = renderer.cgImage else {
            FileHandle.standardError.write(Data("Could not render \(variant.name)\n".utf8)); exit(1)
        }
        let pixels = Int(variant.pixels)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { exit(1) }
        context.interpolationQuality = .high
        context.draw(oversampled, in: CGRect(x: 0, y: 0, width: variant.pixels, height: variant.pixels))
        guard let image = context.makeImage() else { exit(1) }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: variant.pixels, height: variant.pixels)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: iconsetURL.appendingPathComponent(variant.name)) }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetURL)
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Wrote \(outputPath)")
