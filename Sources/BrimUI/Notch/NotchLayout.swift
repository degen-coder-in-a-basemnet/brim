// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import AppKit
import BrimCore

/// Every measurement, quoted in design-frame pixels so it can be checked
/// against the reference frame directly.
enum NotchLayout {
    // MARK: The body

    /// The depth the design fixes: a 44 pt ring with an even margin each side.
    static let sideBodyDepth = Design.px(186)

    /// A horizontal notch is deeper: turned sideways, the percentage under each
    /// ring moves into the notch's depth instead of its length.
    static func bodyDepth(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? sideBodyDepth : 2 * sideRingMargin + cellExtent
    }

    /// Clear space between the ring and the bezel.
    static var sideRingMargin: CGFloat { (sideBodyDepth - ringDiameter) / 2 }

    /// The inverse flare where the body meets the bezel.
    static let curlRadius = Design.px(103)
    /// The small inverse corner where a flush bar meets the screen's frame.
    static let bezelFillet = Design.px(28)
    static let cornerRadius = Design.px(78.8)
    static let padTop = Design.px(69.5)      // body top → first ring
    static let padBottom = Design.px(50.1)   // last label → body bottom
    static let cellSpacing = Design.px(83.5) // label bottom → next ring top

    // MARK: The resting pill

    static let pillWidth = Design.px(26)
    static let pillHeight = Design.px(210)
    /// The pill is small, so the region that wakes it is larger.
    static let pillHotZone = Design.px(90)

    // MARK: A provider cell

    static let ringDiameter = Design.px(117)   // 44 pt, the anchor
    static let trackStroke = Design.px(15.5)
    static let progressStroke = Design.px(8)
    static let glyphSize = Design.px(46)
    static let ringLabelGap = Design.px(26.9)

    /// The activity arc sits between the glyph (46 px) and the track's inner
    /// edge (86 px).
    static let activityDiameter = Design.px(72)
    static let activityStroke = Design.px(5.5)

    // MARK: The attention halo

    /// A waiting agent's dash runs outside its ring, clear of the reading.
    static let attentionGap = Design.px(6)
    static let attentionStroke = Design.px(7)
    static var attentionDiameter: CGFloat { ringDiameter + 2 * (attentionGap + attentionStroke) }

    // MARK: The settings orb

    /// The orb lives past the far end of the notch. At rest only an arc of its
    /// edge shows, concentric with the notch's own bottom flare; on hover the
    /// circle fills and takes a gear.
    static let orbDiameter = Design.px(124)
    static let orbStroke = Design.px(18)
    static let orbGap = Design.px(27)
    static var orbArcRadius: CGFloat { curlRadius - orbGap }
    static let orbGlyph = Design.px(56)
    /// Hiding, the arc grows outward along the flare's normal, a full stroke
    /// past it, so it is buried in the black rather than flying off.
    static var orbMergeScale: CGFloat { (curlRadius + orbStroke) / orbArcRadius }
    static let orbHotZone = Design.px(152)

    /// For a flush bar (no flare to tuck into): the arc hugs the convex corner
    /// from outside by the same gap.
    static func orbConvexArcRadius(corner: CGFloat) -> CGFloat { corner + orbGap }

    /// How far off a convex corner the orb hangs, on each axis.
    static func orbCornerOffset(corner: CGFloat) -> CGFloat {
        (corner + orbGap + orbDiameter / 2) / 2.0.squareRoot()
    }

    // MARK: The tooltip

    static let cardWidth = Design.px(600)
    static let cardCorner = Design.px(49.5)
    static let cardPadding = Design.px(32)
    static let tailLength = Design.px(75)
    static let tailHeight = Design.px(87)
    static let tailGap = Design.px(28)          // tail tip → notch body
    static let barHeight = Design.px(10.5)
    static let headerGap = Design.px(17)        // glyph → title
    static let headerToBlock = Design.px(21)
    static let labelToBar = Design.px(16.8)
    static let barToUsed = Design.px(17.8)
    static let blockSpacing = Design.px(20)
    static let sessionRowGap = Design.px(10)
    static let statusDot = Design.px(17)
    static let statusDotStroke = Design.px(3.4)
    static let statusDotGap = Design.px(11)
    static let hairline = Design.px(2.5)
    static let footGap = Design.px(16)

    // MARK: Line boxes, fixed so AppKit can size the panel before SwiftUI lays out

    static let percentLineHeight: CGFloat = lineHeight(
        NSFont.systemFont(ofSize: Design.fontSize(capPixels: 27), weight: .semibold))
    static let cardTitleLineHeight: CGFloat = lineHeight(
        NSFont.systemFont(ofSize: Design.fontSize(capPixels: 26), weight: .semibold))
    static let cardBodyFont = NSFont.systemFont(ofSize: Design.fontSize(capPixels: 18), weight: .regular)
    static let cardBodyLineHeight: CGFloat = lineHeight(cardBodyFont)
    static let cardFootFont = NSFont.systemFont(ofSize: Design.fontSize(capPixels: 15), weight: .regular)
    static let cardFootLineHeight: CGFloat = lineHeight(cardFootFont)

    static var cardTextWidth: CGFloat { cardWidth - 2 * cardPadding }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// How tall a run of text is once wrapped to the card's column.
    static func textHeight(_ text: String, font: NSFont = cardBodyFont, lineHeight: CGFloat = cardBodyLineHeight) -> CGFloat {
        guard !text.isEmpty else { return lineHeight }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: cardTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return CGFloat(max(1, Int((bounds.height / lineHeight).rounded(.up)))) * lineHeight
    }

    // MARK: Stack geometry

    /// Ring plus the label under it.
    static var cellExtent: CGFloat { ringDiameter + ringLabelGap + percentLineHeight }

    /// What one cell claims along the stack: ring and label down a side edge,
    /// the ring alone across a horizontal one.
    static func cellAlong(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? cellExtent : ringDiameter
    }

    static func cellPitch(for edge: NotchEdge) -> CGFloat { cellAlong(for: edge) + cellSpacing }

    /// Down a side edge the frame's two paddings differ (one pads a ring, the
    /// other a label); across a horizontal edge both pad a ring, so they meet
    /// at their mean.
    static func padStart(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? padTop : (padTop + padBottom) / 2
    }

    static func padEnd(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? padBottom : (padTop + padBottom) / 2
    }

    /// Distance from the start of the shape to cell `index`'s ring centre.
    static func ringCenter(index: Int, edge: NotchEdge, flare: CGFloat, spacing: CGFloat = cellSpacing) -> CGFloat {
        flare + padStart(for: edge) + ringDiameter / 2 + CGFloat(index) * (cellAlong(for: edge) + spacing)
    }

    static func bodyLength(cellCount: Int, edge: NotchEdge, spacing: CGFloat = cellSpacing) -> CGFloat {
        let ends = padStart(for: edge) + padEnd(for: edge)
        guard cellCount > 0 else { return ends }
        return ends + CGFloat(cellCount) * cellAlong(for: edge) + CGFloat(cellCount - 1) * spacing
    }

    /// Full shape length, flares included.
    static func shapeLength(cellCount: Int, edge: NotchEdge, flare: CGFloat, spacing: CGFloat = cellSpacing) -> CGFloat {
        bodyLength(cellCount: cellCount, edge: edge, spacing: spacing) + 2 * flare
    }

    // MARK: Card height, budgeted so the hover region exists before the card does

    static let maxSessionRows = 4

    static func cardHeight(for snapshot: ProviderSnapshot, sessionCount: Int, now: Date) -> CGFloat {
        let header = max(glyphSize, cardTitleLineHeight) + (snapshot.plan != nil ? cardBodyLineHeight : 0)
        var height = 2 * cardPadding + header

        if let blocking = snapshot.blockingWindow(now: now) {
            height += headerToBlock + textHeight(blockedText(blocking, now: now))
        }

        if let message = snapshot.status.message, snapshot.windows.isEmpty {
            height += headerToBlock + textHeight(message)
        } else {
            for (index, window) in snapshot.windows.enumerated() {
                height += index == 0 ? headerToBlock : blockSpacing
                height += windowHeight(window)
            }
        }

        if sessionCount > 0 {
            let shown = min(sessionCount, maxSessionRows)
            height += blockSpacing + hairline
                + CGFloat(shown) * (blockSpacing + 2 * cardBodyLineHeight + sessionRowGap)
            if sessionCount > shown { height += blockSpacing + cardBodyLineHeight }
        }

        if let foot = footText(for: snapshot) {
            height += footGap + textHeight(foot, font: cardFootFont, lineHeight: cardFootLineHeight)
        }
        return ceil(height)
    }

    /// Whether a count row's label and value fit side by side, or need a
    /// second line for the value.
    static func countRowWraps(_ window: LimitWindow) -> Bool {
        let attributes: [NSAttributedString.Key: Any] = [.font: cardBodyFont]
        let label = (window.label as NSString).size(withAttributes: attributes).width
        let value = ((window.detail ?? "") as NSString).size(withAttributes: attributes).width
        return label + Design.px(20) + value > cardTextWidth
    }

    static let countRowLineGap = Design.px(6)

    static func windowHeight(_ window: LimitWindow) -> CGFloat {
        if window.isCountRow {
            return countRowWraps(window) ? 2 * cardBodyLineHeight + countRowLineGap : cardBodyLineHeight
        }
        var height = cardBodyLineHeight                                   // label + reset
        if window.usedFraction != nil { height += labelToBar + barHeight } // bar
        height += barToUsed + cardBodyLineHeight                          // "N% Used"
        if window.note != nil { height += cardFootLineHeight + Design.px(6) }
        return height
    }

    static func blockedText(_ window: LimitWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt else { return "\(window.label) limit reached." }
        return "\(window.label) limit reached · \(ResetCopy.text(for: resetsAt, now: now))"
    }

    /// The fidelity and source line under the windows.
    static func footText(for snapshot: ProviderSnapshot) -> String? {
        let parts = [snapshot.fidelity.title, snapshot.source].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Room past the card's far side for its shadow to fade out.
    static let cardShadowMargin = Design.px(48)

    /// How far the panel reaches past the notch for the card.
    static func tooltipDepth(for edge: NotchEdge, maxCardHeight: CGFloat) -> CGFloat {
        (edge.isVertical ? cardWidth : maxCardHeight) + tailLength + tailGap + cardShadowMargin
    }

    /// Room at each end of the stack for a card centred on the first or last
    /// cell, and for the orb hanging past the foot.
    static func slack(for edge: NotchEdge, maxCardHeight: CGFloat) -> CGFloat {
        edge.isVertical
            ? max(endSlack, maxCardHeight / 2 + cardCorner)
            : max(endSlack, cardWidth / 2 + cardCorner)
    }

    static let endSlack = Design.px(190)
}
