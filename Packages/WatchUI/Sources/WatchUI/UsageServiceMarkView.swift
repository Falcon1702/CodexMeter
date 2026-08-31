import SwiftUI
import UsageCore

/// Compact, single-colour service marks that remain legible in WidgetKit's
/// full-colour, accented, and monochrome rendering modes.
public struct UsageServiceMarkView: View {
    public let brand: UsageServiceBrand?
    public let fallback: String

    public init(
        brand: UsageServiceBrand?,
        fallback: String
    ) {
        self.brand = brand
        self.fallback = fallback
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height), 0)

            ZStack {
                RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
                    .fill(Color.primary.opacity(0.13))

                if let brand {
                    glyph(for: brand)
                        .padding(side * 0.12)
                } else {
                    Text(fallback.uppercased())
                        .font(.system(
                            size: side * 0.66,
                            weight: .bold,
                            design: .rounded
                        ))
                        .minimumScaleFactor(0.35)
                        .allowsTightening(true)
                        .lineLimit(1)
                        .padding(.horizontal, side * 0.12)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func glyph(for brand: UsageServiceBrand) -> some View {
        switch brand {
        case .codex:
            CodexGlyph()
        case .hermes:
            HermesGlyph()
        case .openClaw:
            OpenClawGlyph()
        case .buzz:
            BuzzGlyph()
        }
    }
}

private struct CodexGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let stroke = max(side * 0.095, 0.7)

            ZStack {
                ForEach(0 ..< 6, id: \.self) { index in
                    Capsule(style: .continuous)
                        .stroke(Color.primary, lineWidth: stroke)
                        .frame(width: side * 0.62, height: side * 0.28)
                        .offset(x: side * 0.12)
                        .rotationEffect(.degrees(Double(index) * 60))
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct HermesGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                Capsule(style: .continuous)
                    .fill(Color.primary)
                    .frame(width: side * 0.14, height: side * 0.82)
                    .rotationEffect(.degrees(-18))

                ForEach(0 ..< 3, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(Color.primary)
                        .frame(
                            width: side * (0.68 - Double(index) * 0.13),
                            height: side * 0.13
                        )
                        .offset(
                            x: -side * 0.06,
                            y: side * (-0.22 + Double(index) * 0.19)
                        )
                        .rotationEffect(.degrees(-12))
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct OpenClawGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                clawSegment(side: side, x: -0.22, rotation: -18)
                clawSegment(side: side, x: 0, rotation: 0)
                clawSegment(side: side, x: 0.22, rotation: 18)

                Capsule(style: .continuous)
                    .fill(Color.primary)
                    .frame(width: side * 0.64, height: side * 0.18)
                    .offset(y: side * 0.29)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func clawSegment(
        side: CGFloat,
        x: CGFloat,
        rotation: Double
    ) -> some View {
        Capsule(style: .continuous)
            .fill(Color.primary)
            .frame(width: side * 0.14, height: side * 0.58)
            .offset(x: side * x, y: -side * 0.08)
            .rotationEffect(.degrees(rotation))
    }
}

private struct BuzzGlyph: View {
    var body: some View {
        BuzzMarkShape()
            .fill(Color.primary, style: FillStyle(eoFill: true))
    }
}

private struct BuzzMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sourceSize = CGSize(width: 466, height: 309)
        let scale = min(
            rect.width / sourceSize.width,
            rect.height / sourceSize.height
        )
        let origin = CGPoint(
            x: rect.midX - sourceSize.width * scale / 2,
            y: rect.midY - sourceSize.height * scale / 2
        )

        func scaledRect(
            x: CGFloat,
            y: CGFloat,
            width: CGFloat,
            height: CGFloat
        ) -> CGRect {
            CGRect(
                x: origin.x + x * scale,
                y: origin.y + y * scale,
                width: width * scale,
                height: height * scale
            )
        }

        func point(x: CGFloat, y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        let upperCircleIntersection: CGFloat = 70.3
        let lowerCircleIntersection: CGFloat = 238.7

        // One union outline avoids even-odd cancellation where the two side
        // circles overlap the rounded robot body.
        path.move(to: point(x: 162, y: 0))
        path.addLine(to: point(x: 304, y: 0))
        path.addQuadCurve(
            to: point(x: 338, y: 34),
            control: point(x: 338, y: 0)
        )
        path.addLine(to: point(x: 338, y: upperCircleIntersection))
        path.addArc(
            center: point(x: 374.3, y: 154.5),
            radius: 91.7 * scale,
            startAngle: .degrees(-113.3),
            endAngle: .degrees(113.3),
            clockwise: false
        )
        path.addLine(to: point(x: 338, y: 275))
        path.addQuadCurve(
            to: point(x: 304, y: 309),
            control: point(x: 338, y: 309)
        )
        path.addLine(to: point(x: 162, y: 309))
        path.addQuadCurve(
            to: point(x: 128, y: 275),
            control: point(x: 128, y: 309)
        )
        path.addLine(to: point(x: 128, y: lowerCircleIntersection))
        path.addArc(
            center: point(x: 91.7, y: 154.5),
            radius: 91.7 * scale,
            startAngle: .degrees(66.7),
            endAngle: .degrees(293.3),
            clockwise: false
        )
        path.addLine(to: point(x: 128, y: 34))
        path.addQuadCurve(
            to: point(x: 162, y: 0),
            control: point(x: 128, y: 0)
        )
        path.closeSubpath()

        path.addEllipse(in: scaledRect(x: 166.3, y: 57.4, width: 54, height: 54))
        path.addEllipse(in: scaledRect(x: 249, y: 57.4, width: 54, height: 54))
        path.addRoundedRect(
            in: scaledRect(x: 166.3, y: 157.2, width: 136.9, height: 38.3),
            cornerSize: CGSize(width: 5 * scale, height: 5 * scale)
        )
        path.addRoundedRect(
            in: scaledRect(x: 166.9, y: 235.1, width: 136.2, height: 37.6),
            cornerSize: CGSize(width: 5 * scale, height: 5 * scale)
        )
        return path
    }
}
