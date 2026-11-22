import SwiftUI

// MARK: - Custom glyphs (v0.2.68, MuYu sheet chrome)
// SF Symbols has no broom and no delete-sweep glyph, and no gavel,
// so these are drawn with Paths in a 24x24 box scaled to `size`.
// All three take the same shape as the video's Material icons:
// filled silhouettes in `color` (default the label colour).

/// A broom seen from the side: slanted handle from top-right down
/// to the centre, brush head (fan of bristles) at bottom-left.
/// The video's DNS sheet clear button (Flutter cleaning_services).
struct BroomIcon: View {
    var size: CGFloat = 20
    var color: Color = Color(.label)

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 24
            ZStack {
                // Handle: top-right down to the brush joint.
                Path { path in
                    path.move(to: CGPoint(x: 20.5 * s, y: 1.5 * s))
                    path.addLine(to: CGPoint(x: 11.5 * s, y: 10.5 * s))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2.4 * s, lineCap: .round))
                // Brush head: four bristle quads fanning out from
                // the joint, with hairline gaps between them so the
                // bristles read on any background.
                Path { path in
                    bristle(&path, s: s, topX: 10.2, bottomX0: 1.2, bottomX1: 4.6)
                    bristle(&path, s: s, topX: 11.0, bottomX0: 4.9, bottomX1: 8.3)
                    bristle(&path, s: s, topX: 11.8, bottomX0: 8.6, bottomX1: 12.0)
                    bristle(&path, s: s, topX: 12.6, bottomX0: 12.3, bottomX1: 15.4)
                }
                .fill(color)
                // Binding band across the top of the brush.
                Path { path in
                    path.move(to: CGPoint(x: 8.6 * s, y: 11.2 * s))
                    path.addLine(to: CGPoint(x: 13.6 * s, y: 12.4 * s))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2.0 * s, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }

    /// One bristle: a quad from a point near the joint (`topX`,
    /// y = 12) widening to (`bottomX0`...`bottomX1`, y = 21).
    private func bristle(_ path: inout Path, s: CGFloat, topX: CGFloat, bottomX0: CGFloat, bottomX1: CGFloat) {
        path.move(to: CGPoint(x: (topX - 0.7) * s, y: 12.0 * s))
        path.addLine(to: CGPoint(x: (topX + 0.7) * s, y: 12.0 * s))
        path.addLine(to: CGPoint(x: bottomX1 * s, y: 21.0 * s))
        path.addLine(to: CGPoint(x: bottomX0 * s, y: 21.0 * s))
        path.closeSubpath()
    }
}

/// A trash can (trapezoid body + lid + handle) with three short
/// horizontal lines to its right (Flutter delete_sweep). The video's
/// 运行中 sheet disconnect-all button.
struct DeleteSweepIcon: View {
    var size: CGFloat = 20
    var color: Color = Color(.label)

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 24
            ZStack {
                // Lid.
                Path { path in
                    path.addRoundedRect(in: CGRect(x: 3.5 * s, y: 7.0 * s, width: 12.0 * s, height: 2.2 * s), cornerSize: CGSize(width: 1.1 * s, height: 1.1 * s))
                }
                .fill(color)
                // Lid handle.
                Path { path in
                    path.move(to: CGPoint(x: 7.5 * s, y: 7.0 * s))
                    path.addLine(to: CGPoint(x: 7.5 * s, y: 5.2 * s))
                    path.addLine(to: CGPoint(x: 11.5 * s, y: 5.2 * s))
                    path.addLine(to: CGPoint(x: 11.5 * s, y: 7.0 * s))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))
                // Body: trapezoid, wider at the top.
                Path { path in
                    path.move(to: CGPoint(x: 4.5 * s, y: 10.0 * s))
                    path.addLine(to: CGPoint(x: 14.5 * s, y: 10.0 * s))
                    path.addLine(to: CGPoint(x: 13.2 * s, y: 21.0 * s))
                    path.addLine(to: CGPoint(x: 5.8 * s, y: 21.0 * s))
                    path.closeSubpath()
                }
                .fill(color)
                // Two slits on the body, cut in the page colour so
                // they read on the sheet background.
                Path { path in
                    path.move(to: CGPoint(x: 8.0 * s, y: 12.5 * s))
                    path.addLine(to: CGPoint(x: 8.0 * s, y: 18.5 * s))
                    path.move(to: CGPoint(x: 11.0 * s, y: 12.5 * s))
                    path.addLine(to: CGPoint(x: 11.0 * s, y: 18.5 * s))
                }
                .stroke(ConcordTheme.pageBackground, style: StrokeStyle(lineWidth: 1.2 * s, lineCap: .round))
                // Three sweep lines to the right of the can.
                Path { path in
                    for y in [11.0, 14.5, 18.0] as [CGFloat] {
                        path.move(to: CGPoint(x: 17.5 * s, y: y * s))
                        path.addLine(to: CGPoint(x: 22.5 * s, y: y * s))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// A gavel: tilted rectangular head + handle going down-right +
/// a short horizontal base line below. The Tools 免责声明 icon
/// (the video's icon is a gavel-like shape; SF has no gavel).
struct GavelIcon: View {
    var size: CGFloat = 20
    var color: Color = Color(.label)

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 24
            ZStack {
                // Head: a rectangle rotated 45 degrees (corners
                // computed from centre (9, 8), long half-axis 6,
                // short half-axis 3, at 45 degrees).
                Path { path in
                    path.move(to: CGPoint(x: 6.88 * s, y: 1.64 * s))
                    path.addLine(to: CGPoint(x: 15.36 * s, y: 10.12 * s))
                    path.addLine(to: CGPoint(x: 11.12 * s, y: 14.36 * s))
                    path.addLine(to: CGPoint(x: 2.64 * s, y: 5.88 * s))
                    path.closeSubpath()
                }
                .fill(color)
                // Handle: from the head's lower edge down-right.
                Path { path in
                    path.move(to: CGPoint(x: 12.0 * s, y: 13.0 * s))
                    path.addLine(to: CGPoint(x: 19.0 * s, y: 20.0 * s))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2.4 * s, lineCap: .round))
                // Base line below.
                Path { path in
                    path.move(to: CGPoint(x: 3.0 * s, y: 22.0 * s))
                    path.addLine(to: CGPoint(x: 21.0 * s, y: 22.0 * s))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2.0 * s, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// A horizontal usage bar like the video's config card (~6pt tall):
/// a sine-wave filled path in `color` from the left up to `progress`,
/// then a thin gray track to the right, with a small solid dot in
/// `color` at the wave's end.
struct WavyProgressBar: View {
    var progress: Double
    var color: Color
    var trackColor: Color = Color(.systemGray5)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let clamped = min(1, max(0, progress))
            let endX = width * clamped
            let midY = height * 0.55
            let amplitude = height * 0.28
            let wavelength = max(width / 5, 1)
            let waveY: (CGFloat) -> CGFloat = { x in
                midY - sin(x / wavelength * 2 * .pi) * amplitude
            }
            ZStack(alignment: .topLeading) {
                // Gray track on the right of the wave end.
                if endX < width {
                    Capsule()
                        .fill(trackColor)
                        .frame(width: width - endX, height: 2)
                        .position(x: endX + (width - endX) / 2, y: midY)
                }
                // Sine-wave filled area, left up to `progress`.
                if endX > 0 {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: waveY(0)))
                        let steps = max(8, Int(endX / 2))
                        for step in 1...steps {
                            let x = endX * CGFloat(step) / CGFloat(steps)
                            path.addLine(to: CGPoint(x: x, y: waveY(x)))
                        }
                        path.addLine(to: CGPoint(x: endX, y: height))
                        path.addLine(to: CGPoint(x: 0, y: height))
                        path.closeSubpath()
                    }
                    .fill(color)
                    .frame(width: width, height: height)
                }
                // Solid dot at the wave's end.
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .position(x: min(max(endX, 3.5), max(width - 3.5, 3.5)), y: waveY(endX))
            }
            .frame(width: width, height: height)
        }
    }
}
