// Card chrome, tail and row layout adapted from Codenotch
// (https://github.com/vinzdg/codenotch), MIT License, Copyright (c) 2026 Vinz.
// See THIRD_PARTY_NOTICES.md.
import BrimCore
import SwiftUI

/// The speech-bubble tail, its point on the hovered cell. Its shoulders leave
/// the card tangent to the card's edge, so the two read as one moulded shape.
struct TooltipTail: Shape {
    let direction: NotchEdge.TooltipDirection

    func path(in rect: CGRect) -> Path {
        let tip: CGPoint, a: CGPoint, b: CGPoint
        let aShoulder: CGPoint, aTip: CGPoint, bTip: CGPoint, bShoulder: CGPoint
        switch direction {
        case .leading:
            tip = CGPoint(x: rect.maxX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25)
            aTip = CGPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY - rect.height * 0.12)
            bTip = CGPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY + rect.height * 0.12)
            bShoulder = CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.25)
        case .trailing:
            tip = CGPoint(x: rect.minX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25)
            aTip = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY - rect.height * 0.12)
            bTip = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY + rect.height * 0.12)
            bShoulder = CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.25)
        case .down:
            tip = CGPoint(x: rect.midX, y: rect.minY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY)
            aTip = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.minY + rect.height * 0.42)
            bTip = CGPoint(x: rect.midX + rect.width * 0.12, y: rect.minY + rect.height * 0.42)
            bShoulder = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.maxY)
        case .up:
            tip = CGPoint(x: rect.midX, y: rect.maxY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
            aShoulder = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY)
            aTip = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.maxY - rect.height * 0.42)
            bTip = CGPoint(x: rect.midX + rect.width * 0.12, y: rect.maxY - rect.height * 0.42)
            bShoulder = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.minY)
        }
        var path = Path()
        path.move(to: a)
        path.addCurve(to: tip, control1: aShoulder, control2: aTip)
        path.addCurve(to: b, control1: bTip, control2: bShoulder)
        path.closeSubpath()
        return path
    }

    static func size(for direction: NotchEdge.TooltipDirection) -> CGSize {
        switch direction {
        case .leading, .trailing: return CGSize(width: NotchLayout.tailLength, height: NotchLayout.tailHeight)
        case .up, .down:          return CGSize(width: NotchLayout.tailHeight, height: NotchLayout.tailLength)
        }
    }
}

/// Card chrome: fixed width, the frame's padding and corner, the tail welded on.
private struct TooltipShell<Content: View>: View {
    /// Given explicitly, so the card and its tail glide together instead of the
    /// tail jumping when the contents change.
    let height: CGFloat
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    @ViewBuilder let content: Content

    private var card: some View {
        // The contents are laid out once at their natural size and the mask
        // changes over them, so rows never drift while the card resizes.
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(Palette.card)
                .frame(width: NotchLayout.cardWidth, height: height)
            content
                .padding(NotchLayout.cardPadding)
                .frame(width: NotchLayout.cardWidth, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
        .shadow(color: .black.opacity(0.35), radius: Design.px(24), y: Design.px(8))
    }

    private var clampedTailOffset: CGFloat {
        let size = TooltipTail.size(for: direction)
        switch direction {
        case .leading, .trailing:
            let limit = max(0, height / 2 - NotchLayout.cardCorner - size.height / 2)
            return min(max(tailOffset, -limit), limit)
        case .up, .down:
            let limit = max(0, NotchLayout.cardWidth / 2 - NotchLayout.cardCorner - size.width / 2)
            return min(max(tailOffset, -limit), limit)
        }
    }

    private var tail: some View {
        let size = TooltipTail.size(for: direction)
        return TooltipTail(direction: direction)
            .fill(Palette.card)
            .frame(width: size.width, height: size.height)
            .offset(x: direction == .up || direction == .down ? clampedTailOffset : 0,
                    y: direction == .leading || direction == .trailing ? clampedTailOffset : 0)
    }

    var body: some View {
        switch direction {
        case .leading:  HStack(spacing: 0) { card; tail }
        case .trailing: HStack(spacing: 0) { tail; card }
        case .down:     VStack(spacing: 0) { tail; card }
        case .up:       VStack(spacing: 0) { card; tail }
        }
    }
}

/// A label on the left and a quieter value on the right.
struct SplitRow<Accessory: View>: View {
    let leading: String
    let trailing: String
    var leadingColor: Color = Palette.textPrimary
    var trailingColor: Color = Palette.textSecondary
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Design.px(20)) {
            Text(leading).foregroundStyle(leadingColor)
            Spacer(minLength: 0)
            HStack(spacing: NotchLayout.statusDotGap) {
                accessory()
                Text(trailing).foregroundStyle(trailingColor)
            }
        }
        .font(Typography.cardBody)
        .lineLimit(1)
        .frame(height: NotchLayout.cardBodyLineHeight)
    }
}

extension SplitRow where Accessory == EmptyView {
    init(leading: String, trailing: String, leadingColor: Color = Palette.textPrimary,
         trailingColor: Color = Palette.textSecondary) {
        self.init(leading: leading, trailing: trailing, leadingColor: leadingColor,
                  trailingColor: trailingColor, accessory: { EmptyView() })
    }
}

/// One metered window: label and reset on a line, a bar, then what is used.
private struct LimitWindowRow: View {
    let window: LimitWindow
    let fidelity: Fidelity
    let now: Date
    let format: ResetTimeFormat
    @Environment(\.brimAccent) private var accent

    private var band: UsageBand { UsageBand.band(for: window.usedFraction ?? 0) }
    private var trackWidth: CGFloat { NotchLayout.cardTextWidth }
    private var fillWidth: CGFloat {
        let fraction = CGFloat(min(max(window.usedFraction ?? 0, 0), 1))
        return max(NotchLayout.barHeight, trackWidth * fraction)
    }

    private var resetText: String {
        window.resetsAt.map { ResetCopy.text(for: $0, now: now, format: format) } ?? ""
    }

    private var usedText: String {
        let marker = (window.fidelity ?? fidelity).qualifier
        switch (window.usedFraction, window.detail) {
        case let (fraction?, detail?) where fidelity != .manual && (window.fidelity ?? fidelity) != .local:
            return "\(marker)\(Percent.text(for: fraction)) Used · \(detail)"
        case let (fraction?, detail?):
            return "\(Percent.text(for: fraction)) · \(detail)"
        case let (fraction?, nil):
            return "\(marker)\(Percent.text(for: fraction)) Used"
        case let (nil, detail?):
            return detail
        case (nil, nil):
            return "No reading"
        }
    }

    private var barColor: Color {
        (window.fidelity ?? fidelity) == .local ? Palette.local : band.color(accent: accent)
    }

    var body: some View {
        if window.isCountRow {
            if NotchLayout.countRowWraps(window) {
                VStack(alignment: .leading, spacing: NotchLayout.countRowLineGap) {
                    Text(window.label).foregroundStyle(Palette.textPrimary)
                        .frame(height: NotchLayout.cardBodyLineHeight)
                    Text(window.detail ?? "").foregroundStyle(Palette.textSecondary)
                        .frame(height: NotchLayout.cardBodyLineHeight)
                }
                .font(Typography.cardBody)
                .lineLimit(1)
                .truncationMode(.middle)
            } else {
                SplitRow(leading: window.label, trailing: window.detail ?? "")
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SplitRow(leading: window.label, trailing: resetText)
                if window.usedFraction != nil {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.barTrack)
                        Capsule().fill(barColor).frame(width: fillWidth)
                            .animation(NotchMotion.reading, value: fillWidth)
                    }
                    .frame(width: trackWidth, height: NotchLayout.barHeight)
                    .padding(.top, NotchLayout.labelToBar)
                }
                Text(usedText)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(height: NotchLayout.cardBodyLineHeight)
                    .padding(.top, NotchLayout.barToUsed)
                if let note = window.note {
                    Text(note)
                        .font(Typography.cardFoot)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .frame(height: NotchLayout.cardFootLineHeight)
                        .padding(.top, Design.px(6))
                }
            }
        }
    }
}

/// The ring beside a session's status: turning while it works.
private struct StatusRing: View {
    let state: SessionState
    var still = false

    var body: some View {
        Group {
            if state == .busy && !still {
                TimelineView(.animation) { context in
                    ring(trim: 0.75)
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.4) / 1.4 * 360))
                }
            } else {
                ring(trim: state == .busy ? 0.75 : (state == .waiting ? 0.5 : 1))
            }
        }
        .frame(width: NotchLayout.statusDot, height: NotchLayout.statusDot)
    }

    private func ring(trim: CGFloat) -> some View {
        Circle().trim(from: 0, to: trim)
            .stroke(state == .idle ? Palette.textSecondary : state.color,
                    style: StrokeStyle(lineWidth: NotchLayout.statusDotStroke, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

/// One session in a card. A click hands on this row's own session, process id
/// and all: never another.
struct SessionRow: View {
    let session: AgentSession
    let now: Date
    var highlighted = false
    var still = false
    var onFocus: ((AgentSession) -> Void)?

    func focus() { onFocus?(session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SplitRow(leading: session.name, trailing: session.state.word,
                     leadingColor: highlighted ? Palette.watch : Palette.textPrimary,
                     trailingColor: session.state == .idle ? Palette.textSecondary : session.state.color) {
                StatusRing(state: session.state, still: still)
            }
            SplitRow(leading: session.state == .waiting ? (session.waitingFor ?? session.detail) : session.detail,
                     trailing: ElapsedCopy.duration(since: session.since, now: now),
                     leadingColor: Palette.textSecondary)
                .padding(.top, NotchLayout.sessionRowGap)
        }
        .padding(.top, NotchLayout.blockSpacing)
        .contentShape(Rectangle())
        .onTapGesture { focus() }
    }
}

struct SessionList: View {
    let summary: ActivitySummary
    let now: Date
    var highlighted: String?
    var still = false
    var onFocus: ((AgentSession) -> Void)?

    /// The sessions a card lists, in its order: waiting, then working, newest
    /// first, up to the row limit.
    static func shown(_ summary: ActivitySummary) -> [AgentSession] {
        Array(summary.ordered.prefix(NotchLayout.maxSessionRows))
    }

    var body: some View {
        let ordered = summary.ordered
        let shown = Self.shown(summary)
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.ringTrack).frame(height: NotchLayout.hairline)
                .padding(.top, NotchLayout.blockSpacing)
            ForEach(shown) { session in
                SessionRow(session: session, now: now, highlighted: session.id == highlighted, still: still,
                           onFocus: onFocus)
            }
            if ordered.count > shown.count {
                Text("and \(ordered.count - shown.count) more")
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(height: NotchLayout.cardBodyLineHeight)
                    .padding(.top, NotchLayout.blockSpacing)
            }
        }
    }
}

/// The hover card for one provider.
struct TooltipCard: View {
    let snapshot: ProviderSnapshot
    var activity: ActivitySummary?
    let now: Date
    var direction: NotchEdge.TooltipDirection = .leading
    var format: ResetTimeFormat = .automatic
    var tailOffset: CGFloat = 0
    var highlightedSession: String?
    var still = false
    var onFocusSession: ((AgentSession) -> Void)?

    private var height: CGFloat {
        NotchLayout.cardHeight(for: snapshot, sessionCount: activity?.sessions.count ?? 0, now: now)
    }

    /// Dated when the numbers are not current, so a remembered reading never
    /// passes itself off as live.
    private var headerNote: String? {
        if let since = snapshot.status.staleSince { return "as of \(ElapsedCopy.ago(since: since, now: now))" }
        if snapshot.status.isProblem { return snapshot.status.label }
        return nil
    }

    private var title: String {
        snapshot.fidelity == .local ? "\(snapshot.displayName) · Local" : "\(snapshot.displayName) Usage"
    }

    var body: some View {
        TooltipShell(height: height, direction: direction, tailOffset: tailOffset) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let blocking = snapshot.blockingWindow(now: now) {
                    HStack(alignment: .firstTextBaseline, spacing: NotchLayout.statusDotGap) {
                        Image(systemName: "pause.circle.fill").font(.system(size: NotchLayout.statusDot))
                        Text(NotchLayout.blockedText(blocking, now: now)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.critical)
                    .padding(.top, NotchLayout.headerToBlock)
                }
                if let message = snapshot.status.message, snapshot.windows.isEmpty {
                    Text(message)
                        .font(Typography.cardBody)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, NotchLayout.headerToBlock)
                } else {
                    ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { index, window in
                        LimitWindowRow(window: window, fidelity: snapshot.fidelity, now: now, format: format)
                            .padding(.top, index == 0 ? NotchLayout.headerToBlock : NotchLayout.blockSpacing)
                    }
                }
                if let activity, !activity.isEmpty {
                    SessionList(summary: activity, now: now, highlighted: highlightedSession, still: still,
                                onFocus: onFocusSession)
                }
                if let foot = NotchLayout.footText(for: snapshot) {
                    HStack(alignment: .firstTextBaseline, spacing: Design.px(8)) {
                        Text(foot).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Typography.cardFoot)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, NotchLayout.footGap)
                }
            }
            .id(snapshot.id)
            .transition(.opacity.animation(NotchMotion.crossfade))
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NotchLayout.headerGap) {
            ProviderGlyphView(glyph: snapshot.glyph).foregroundStyle(Palette.textPrimary)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let headerNote {
                        Spacer(minLength: Design.px(20))
                        Text(headerNote)
                            .font(Typography.cardBody)
                            .foregroundStyle(snapshot.status.isProblem ? Palette.watch : Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                if let plan = snapshot.plan {
                    Text(plan).font(Typography.cardBody).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
            }
        }
        .frame(height: max(NotchLayout.glyphSize, NotchLayout.cardTitleLineHeight)
               + (snapshot.plan != nil ? NotchLayout.cardBodyLineHeight : 0), alignment: .leading)
    }
}
