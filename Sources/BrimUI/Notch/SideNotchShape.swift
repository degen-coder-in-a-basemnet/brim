// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import BrimCore
import SwiftUI

/// The notch body: a pill welded to one edge of the screen, with inverse
/// rounded corners at each end that flare back out to the edge so it reads as
/// part of the bezel rather than a floating panel.
///
/// The path is written once, for the right edge, and transformed onto
/// whichever edge it is on. In canonical form `rect` is the whole shape with
/// its flares; the straight body runs between them and `rect.maxX` is the
/// screen edge.
struct SideNotchShape: Shape {
    var edge: NotchEdge = .right
    /// The display's own camera notch, when this shape grows out of it. The
    /// flares go (the hardware notch does not taper) and the corner is capped
    /// at half the hardware's height so it is the same shape folded or open.
    var joining: HardwareNotch?
    var curlRadius: CGFloat = NotchLayout.curlRadius
    var cornerRadius: CGFloat = NotchLayout.cornerRadius

    /// What morphs as the notch folds: the corner opens out with the spring
    /// rather than snapping to its new value on the first frame.
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let depth = edge.isVertical ? rect.width : rect.height
        let length = edge.isVertical ? rect.height : rect.width
        let canonical = canonicalPath(
            in: CGRect(x: 0, y: 0, width: depth, height: length),
            flare: joining == nil ? curlRadius : NotchLayout.bezelFillet,
            cornerCap: joining.map { $0.height / 2 } ?? .greatestFiniteMagnitude)
        return canonical
            .applying(Self.transform(for: edge, depth: depth))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Canonical (`u` across from the far side, `v` along) onto the rect's own
    /// coordinates, with the bezel landing on the notch's edge.
    static func transform(for edge: NotchEdge, depth: CGFloat) -> CGAffineTransform {
        switch edge {
        case .right:  return .identity
        case .left:   return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: depth, ty: 0)
        case .top:    return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: depth)
        case .bottom: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        }
    }

    /// The handle reach that makes a cubic Bézier trace a circle. Every corner
    /// here is a circular arc: anything cleverer puts a curvature jump at the
    /// join with the straight, which the eye reads as a kink.
    static let circleReach: CGFloat = 0.5523

    /// A quarter turn whose bend ramps in from nothing at both ends, integrated
    /// from its curvature and walked out as a fine polyline. Used for the
    /// flares, where a plain arc arrives with its whole bend at once and reads
    /// as a stiff join against the bezel.
    private func fluidTurn(_ path: inout Path, to: CGPoint, leaving: CGVector, arriving: CGVector, ramp: CGFloat) {
        guard let from = path.currentPoint else { return }
        let alongReach = (to.x - from.x) * leaving.dx + (to.y - from.y) * leaving.dy
        let acrossReach = (to.x - from.x) * arriving.dx + (to.y - from.y) * arriving.dy
        guard alongReach != 0, acrossReach != 0 else {
            path.addLine(to: to)
            return
        }
        let p = min(max(ramp, 0), 0.5)
        let bend = (CGFloat.pi / 2) / (1 - p)
        let steps = 96
        var heading: CGFloat = 0, u: CGFloat = 0, v: CGFloat = 0
        var walk: [(CGFloat, CGFloat)] = [(0, 0)]
        for i in 0..<steps {
            let s = (CGFloat(i) + 0.5) / CGFloat(steps)
            let share = p <= 0 ? 1 : (s < p ? s / p : (s > 1 - p ? (1 - s) / p : 1))
            heading += bend * share / CGFloat(steps)
            u += cos(heading) / CGFloat(steps)
            v += sin(heading) / CGFloat(steps)
            walk.append((u, v))
        }
        let (endU, endV) = walk[walk.count - 1]
        let alongScale = alongReach / endU, acrossScale = acrossReach / endV
        for (wu, wv) in walk.dropFirst() {
            path.addLine(to: CGPoint(
                x: from.x + leaving.dx * wu * alongScale + arriving.dx * wv * acrossScale,
                y: from.y + leaving.dy * wu * alongScale + arriving.dy * wv * acrossScale))
        }
    }

    /// A circular quarter turn from the current point to `to`.
    private func turn(_ path: inout Path, to: CGPoint, leaving: CGVector, arriving: CGVector, radius: CGFloat) {
        guard radius > 0, let from = path.currentPoint else {
            path.addLine(to: to)
            return
        }
        let delta = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let out = abs(delta.dx * leaving.dx + delta.dy * leaving.dy)
        let into = abs(delta.dx * arriving.dx + delta.dy * arriving.dy)
        guard out > 0, into > 0 else {
            path.addLine(to: to)
            return
        }
        path.addCurve(to: to,
                      control1: CGPoint(x: from.x + leaving.dx * out * Self.circleReach,
                                        y: from.y + leaving.dy * out * Self.circleReach),
                      control2: CGPoint(x: to.x - arriving.dx * into * Self.circleReach,
                                        y: to.y - arriving.dy * into * Self.circleReach))
    }

    private func canonicalPath(in rect: CGRect, flare: CGFloat, cornerCap: CGFloat) -> Path {
        // The corner is claimed first, out of half the width, and the flare
        // takes what is left — so the folded pill keeps rounded corners.
        let wanted = max(0, min(cornerRadius, cornerCap, rect.width / 2))
        let curl = max(0, min(flare, rect.width - wanted))
        let corner = max(0, min(wanted, (rect.height - 2 * curl) / 2))
        let bodyTop = rect.minY + curl
        let bodyBottom = rect.maxY - curl

        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        if curl > 0 {
            fluidTurn(&path, to: CGPoint(x: rect.maxX - curl, y: bodyTop),
                      leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: -1, dy: 0), ramp: 0)
        }
        path.addLine(to: CGPoint(x: rect.minX + corner, y: bodyTop))
        turn(&path, to: CGPoint(x: rect.minX, y: bodyTop + corner),
             leaving: CGVector(dx: -1, dy: 0), arriving: CGVector(dx: 0, dy: 1), radius: corner)
        path.addLine(to: CGPoint(x: rect.minX, y: bodyBottom - corner))
        turn(&path, to: CGPoint(x: rect.minX + corner, y: bodyBottom),
             leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: 1, dy: 0), radius: corner)
        path.addLine(to: CGPoint(x: rect.maxX - curl, y: bodyBottom))
        if curl > 0 {
            fluidTurn(&path, to: CGPoint(x: rect.maxX, y: rect.maxY),
                      leaving: CGVector(dx: 1, dy: 0), arriving: CGVector(dx: 0, dy: 1), ramp: 0)
        }
        path.closeSubpath()
        return path
    }
}
