// Composition adapted from Codenotch (https://github.com/vinzdg/codenotch),
// MIT License, Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import BrimCore
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    /// Snapshot renders freeze everything that would otherwise move.
    var still = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the shape overhangs the bezel, so no hairline of wallpaper shows
    /// between the notch and the screen edge.
    static let bezelBleed: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let place = NotchPlacement(edge: model.edge, panelSize: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.clear

                notch(place)

                SettingsOrb(isHovered: model.isHoveringSettings, edge: model.edge, convex: model.orbHugsCorner,
                            arcRadius: model.orbArcRadius, arcOffset: model.orbArcOffset, spins: model.settingsSpins)
                    .contentShape(Circle())
                    .onTapGesture {
                        model.settingsSpins += 1
                        model.onOpenSettings?()
                    }
                    // Scaled about its own centre — the flare's centre of
                    // curvature — so hiding carries the arc outward into the
                    // black instead of off across the screen.
                    .scaleEffect(model.sizeScale * (model.isExpanded ? 1 : model.orbMergeScale))
                    .opacity(model.isExpanded ? 1 : 0)
                    .animation(motion(orbMotion), value: model.isExpanded)
                    .position(orbCentre(place))

                if model.isExpanded, let snapshot = model.hoveredSnapshot, let index = model.hoveredIndex {
                    TooltipCard(snapshot: snapshot, activity: model.activity(for: snapshot), now: model.now,
                                direction: model.edge.tooltipDirection, format: model.resetFormat,
                                tailOffset: tailOffset(index: index, snapshot: snapshot),
                                highlightedSession: model.peekSessionID, still: still,
                                onFocusSession: model.onFocusSession)
                        // One card that travels between cells, not one leaving
                        // and another arriving.
                        .position(tooltipCentre(place, index: index, snapshot: snapshot))
                        .transition(.opacity.combined(with: .offset(x: model.edge.outward.x * Design.px(24),
                                                                    y: model.edge.outward.y * Design.px(24))))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(motion(NotchMotion.glide), value: model.hoveredIndex)
        }
        .animation(motion(NotchMotion.unfold), value: model.isExpanded)
        .environment(\.brimAccent, model.accent)
        .environment(\.colorScheme, .dark)
    }

    /// Arriving, the arc waits its turn behind the cells; leaving, it goes at
    /// once so it is inside the black while there is still black to be inside.
    private var orbMotion: Animation {
        model.isExpanded ? NotchMotion.stagger(index: model.snapshots.count) : NotchMotion.merge
    }

    private func notch(_ place: NotchPlacement) -> some View {
        model.notchShape
            .fill(Palette.notch)
            .frame(width: model.notchSize.width, height: model.notchSize.height)
            .overlay(alignment: contentAlignment) {
                cells.padding(bezelSide, model.contentInset)
            }
            // Masked by the notch itself, so the readings are swallowed by the
            // outline as it closes rather than sliding out of its end.
            .clipShape(model.notchShape)
            // Scaled from the bezel, so the outer edge is a fixed point.
            .scaleEffect(model.sizeScale, anchor: bezelAnchor)
            .position(place.point(along: place.panelLength / 2, across: model.notchDepth / 2))
            .offset(x: model.edge.outward.x * Self.bezelBleed, y: model.edge.outward.y * Self.bezelBleed)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Brim usage notch")
    }

    @ViewBuilder
    private var cells: some View {
        let stack = ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, snapshot in
            ProviderCell(snapshot: snapshot, activity: model.activity(for: snapshot)?.state,
                         needsAttention: model.needsAttention(snapshot),
                         isRefreshing: model.isRefreshing(snapshot), now: model.now, staticActivity: still)
                .frame(width: model.edge.isVertical ? nil : NotchLayout.cellAlong(for: model.edge))
                .opacity(model.isExpanded ? 1 : 0)
                .offset(x: model.isExpanded ? 0 : model.edge.outward.x * Design.px(28),
                        y: model.isExpanded ? 0 : model.edge.outward.y * Design.px(28))
                .animation(motion(NotchMotion.stagger(index: index)), value: model.isExpanded)
                .transition(.opacity.combined(with: .offset(x: model.edge.outward.x * Design.px(28),
                                                            y: model.edge.outward.y * Design.px(28))))
        }
        Group {
            if model.edge.isVertical {
                VStack(spacing: model.cellSpacing) { stack }
                    .padding(.top, model.cellsLeadIn)
                    .frame(width: NotchLayout.bodyDepth(for: model.edge))
            } else {
                HStack(spacing: model.cellSpacing) { stack }
                    .padding(.leading, model.cellsLeadIn)
                    .frame(height: NotchLayout.bodyDepth(for: model.edge))
            }
        }
        .allowsHitTesting(false)
    }

    private var contentAlignment: Alignment {
        switch model.edge {
        case .right:  return .topTrailing
        case .left:   return .topLeading
        case .top:    return .topLeading
        case .bottom: return .bottomLeading
        }
    }

    private var bezelSide: Edge.Set {
        switch model.edge {
        case .right:  return .trailing
        case .left:   return .leading
        case .top:    return .top
        case .bottom: return .bottom
        }
    }

    private var bezelAnchor: UnitPoint {
        switch model.edge {
        case .right:  return .trailing
        case .left:   return .leading
        case .top:    return .top
        case .bottom: return .bottom
        }
    }

    private func motion(_ animation: Animation) -> Animation? {
        still ? nil : NotchMotion.respectingReduceMotion(animation, reduceMotion)
    }

    private func orbCentre(_ place: NotchPlacement) -> CGPoint {
        let startOfShape = model.slack
        return place.point(along: startOfShape + model.orbAlong * model.sizeScale,
                           across: model.orbInset * model.sizeScale)
    }

    private func cardAlongLength(_ snapshot: ProviderSnapshot) -> CGFloat {
        model.edge.isVertical ? model.cardHeight(for: snapshot) : NotchLayout.cardWidth
    }

    private func tailOffset(index: Int, snapshot: ProviderSnapshot) -> CGFloat {
        model.slack + model.ringCenter(index: index) * model.sizeScale
            - model.tooltipAlong(index: index, length: cardAlongLength(snapshot))
    }

    private func tooltipCentre(_ place: NotchPlacement, index: Int, snapshot: ProviderSnapshot) -> CGPoint {
        let across = model.edge.isVertical ? NotchLayout.cardWidth : model.cardHeight(for: snapshot)
        return place.point(along: model.tooltipAlong(index: index, length: cardAlongLength(snapshot)),
                           across: model.tooltipInset + (NotchLayout.tailLength + across) / 2)
    }
}
