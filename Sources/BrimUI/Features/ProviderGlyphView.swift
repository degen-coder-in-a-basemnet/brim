import BrimCore
import SwiftUI

/// The mark in the middle of a ring, drawn by Brim rather than taken from a
/// vendor's artwork.
struct ProviderGlyphView: View {
    let glyph: ProviderGlyph
    var size: CGFloat = NotchLayout.glyphSize

    var body: some View {
        Group {
            switch glyph {
            case .asterisk:
                Starburst().fill(style: FillStyle())
            case .prompt:
                PromptMark().stroke(style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round, lineJoin: .round))
                    .padding(size * 0.08)
            case .symbol(let name):
                Image(systemName: name)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(.medium)
                    .padding(size * 0.06)
            case .monogram(let text):
                Text(String(text.prefix(2)))
                    .font(.system(size: size * (text.count > 1 ? 0.62 : 0.8), weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Twelve tapered rays of alternating length.
struct Starburst: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let rays = 12
        for index in 0..<rays {
            let angle = Double(index) / Double(rays) * 2 * .pi - .pi / 2 + 0.13
            let length = outer * (index.isMultiple(of: 2) ? 1.0 : 0.82)
            let width = outer * 0.13
            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            let base = CGPoint(x: centre.x + direction.dx * outer * 0.12, y: centre.y + direction.dy * outer * 0.12)
            let tip = CGPoint(x: centre.x + direction.dx * length, y: centre.y + direction.dy * length)
            path.move(to: CGPoint(x: base.x + normal.dx * width, y: base.y + normal.dy * width))
            path.addLine(to: CGPoint(x: tip.x + normal.dx * width * 0.45, y: tip.y + normal.dy * width * 0.45))
            path.addQuadCurve(to: CGPoint(x: tip.x - normal.dx * width * 0.45, y: tip.y - normal.dy * width * 0.45),
                              control: CGPoint(x: tip.x + direction.dx * width * 0.6, y: tip.y + direction.dy * width * 0.6))
            path.addLine(to: CGPoint(x: base.x - normal.dx * width, y: base.y - normal.dy * width))
            path.closeSubpath()
        }
        path.addEllipse(in: CGRect(x: centre.x - outer * 0.2, y: centre.y - outer * 0.2,
                                   width: outer * 0.4, height: outer * 0.4))
        return path
    }
}

/// A prompt chevron with a cursor bar.
struct PromptMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.24))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.46, y: rect.minY + h * 0.5))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.76))
        path.move(to: CGPoint(x: rect.minX + w * 0.56, y: rect.minY + h * 0.78))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.9, y: rect.minY + h * 0.78))
        return path
    }
}
