import AppKit
import BrimCore
import SwiftUI

/// Renders the notch to PNG files from demo data, for visual QA without a
/// screen recording and without reading anything on this Mac:
///
///     Brim.app/Contents/MacOS/Brim --render-snapshots build/snapshots
@MainActor
enum SnapshotRenderer {
    /// A fixed moment, so every render is identical.
    static let moment = ISO8601DateFormatter().date(from: "2026-09-24T11:22:30Z") ?? Date()

    struct Scene {
        let name: String
        var edge: NotchEdge = .right
        var expanded = true
        var hovered: Int?
        var size: NotchSize = .medium
        var hardwareNotch: HardwareNotch?
        var orbHover = false
        var accent: AccentChoice = .green
        var staleFirst = false
        var peekSession: String?
        var waiting: Set<String> = []
    }

    static let scenes: [Scene] = [
        Scene(name: "01-right-collapsed", expanded: false),
        Scene(name: "02-right-expanded"),
        Scene(name: "03-right-tooltip-claude", hovered: 0),
        Scene(name: "04-right-tooltip-codex", hovered: 1),
        Scene(name: "05-right-tooltip-manual", hovered: 2),
        Scene(name: "06-right-tooltip-local", hovered: 3),
        Scene(name: "07-right-orb-hover", orbHover: true),
        Scene(name: "08-left-tooltip", edge: .left, hovered: 0),
        Scene(name: "09-top-tooltip", edge: .top, hovered: 1),
        Scene(name: "10-bottom-tooltip", edge: .bottom, hovered: 2),
        Scene(name: "11-top-hardware-collapsed", edge: .top, expanded: false,
              hardwareNotch: HardwareNotch(width: 185, height: 32)),
        Scene(name: "12-top-hardware-expanded", edge: .top, hovered: 0, hardwareNotch: HardwareNotch(width: 185, height: 32)),
        Scene(name: "13-right-small", size: .small),
        Scene(name: "14-right-large", size: .large),
        Scene(name: "15-right-stale", hovered: 0, staleFirst: true),
        Scene(name: "16-right-peek", hovered: 0, peekSession: "demo.claude.1"),
        Scene(name: "17-right-waiting", waiting: ["demo.claude"]),
        Scene(name: "18-top-waiting", edge: .top, waiting: ["demo.codex"]),
    ]

    static func renderAll(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scene in scenes {
            let url = directory.appendingPathComponent("\(scene.name).png")
            if let data = render(scene) {
                try? data.write(to: url)
                print("rendered \(url.lastPathComponent)")
            } else {
                print("failed \(scene.name)")
            }
        }
    }

    static func model(for scene: Scene) -> NotchViewModel {
        let model = NotchViewModel()
        var snapshots = DemoData.snapshots(now: moment)
        if scene.staleFirst {
            snapshots[0] = snapshots[0].markedStale(since: moment.addingTimeInterval(-3 * 3600))
        }
        model.snapshots = snapshots
        let sessions = DemoData.sessions(now: moment)
        model.activity = Dictionary(grouping: sessions, by: \.providerID).mapValues { ActivitySummary(sessions: $0) }
        model.now = moment
        model.edge = scene.edge
        model.sizeScale = CGFloat(scene.size.scale)
        model.accent = scene.accent.color
        model.hardwareNotch = scene.hardwareNotch
        model.screenSize = CGSize(width: 1512, height: 982)
        model.isExpanded = scene.expanded
        model.hoveredIndex = scene.hovered
        model.isHoveringSettings = scene.orbHover
        model.peekSessionID = scene.peekSession
        model.waitingProviders = scene.waiting
        return model
    }

    static func render(_ scene: Scene) -> Data? {
        let model = model(for: scene)
        let size = model.panelSize
        let view = ZStack {
            Wallpaper()
            NotchRootView(model: model, still: true)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        guard let image = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}

/// A stand-in desktop, so the black notch has something to be read against.
private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0E7C8C), Color(hex: 0x39A9C9), Color(hex: 0x1D5F86)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            LinearGradient(colors: [.clear, Color(hex: 0xE0662C).opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .rotationEffect(.degrees(-24))
                .blur(radius: 30)
        }
    }
}
