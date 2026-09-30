import AppKit
import BrimCore
import Darwin

/// Brings the app a session runs in to the front, and its tab where the
/// terminal allows it.
///
/// A session carries only its process id; everything else is looked up at the
/// moment of the click and kept nowhere. Whether the process still runs. The app
/// that hosts it, found by walking up the process tree to the first regular app:
/// the terminal or editor that launched the agent. And the agent's terminal
/// device (its TTY), which names its tab. Terminal and iTerm2 select the tab
/// holding a device when asked over Apple Events, which macOS lets you allow or
/// refuse the first time. For any other app, or after a refusal, the app is
/// simply brought forward. Nothing is logged or sent anywhere.
enum SessionFocus {
    /// Terminals that can select a tab by its device.
    enum ScriptableTerminal: String, CaseIterable {
        case terminal = "com.apple.Terminal"
        case iTerm = "com.googlecode.iterm2"
    }

    /// One process, as the kernel describes it.
    struct ProcessEntry: Equatable {
        var parent: pid_t?
        var name: String
        /// Its controlling terminal, e.g. "/dev/ttys003".
        var device: String?
    }

    /// The process table, as far as focusing needs it. Replaced in tests.
    struct Processes {
        var isRunning: (pid_t) -> Bool
        var entry: (pid_t) -> ProcessEntry?
        /// The bundle identifier of the regular app running as this process
        /// ("" for one without), or nil when it is not a regular app.
        var regularApp: (pid_t) -> String?
        /// A running app's process, by bundle identifier.
        var runningApp: (String) -> pid_t?
    }

    /// What a click can do for a session's process.
    enum Plan: Equatable {
        /// Select the tab on `device` in that terminal, and bring it forward.
        case selectTab(device: String, terminal: ScriptableTerminal, app: pid_t)
        /// Bring the app forward.
        case bringForward(app: pid_t)
        /// The process has gone, or nothing that hosts it can be named.
        case nothing
    }

    static let maxDepth = 24

    static func isRunning(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    static func plan(for pid: pid_t, in processes: Processes) -> Plan {
        guard processes.isRunning(pid), let agent = processes.entry(pid) else { return .nothing }
        var current: pid_t? = pid
        var depth = 0
        while let candidate = current, depth < maxDepth {
            if let bundleID = processes.regularApp(candidate) {
                return plan(bundleID: bundleID, app: candidate, device: agent.device)
            }
            let entry = candidate == pid ? agent : processes.entry(candidate)
            // iTerm2 runs its sessions under a server process that is not a
            // child of the app and outlives it.
            if entry?.name.hasPrefix("iTermServer") == true,
               let app = processes.runningApp(ScriptableTerminal.iTerm.rawValue) {
                return plan(bundleID: ScriptableTerminal.iTerm.rawValue, app: app, device: agent.device)
            }
            current = entry?.parent
            depth += 1
        }
        return .nothing
    }

    private static func plan(bundleID: String, app: pid_t, device: String?) -> Plan {
        if let terminal = ScriptableTerminal(rawValue: bundleID), let device, isTerminalDevice(device) {
            return .selectTab(device: device, terminal: terminal, app: app)
        }
        return .bringForward(app: app)
    }

    /// Only a pseudo-terminal's path ever reaches a script.
    static func isTerminalDevice(_ path: String) -> Bool {
        path.range(of: #"^/dev/ttys[0-9]{1,5}$"#, options: .regularExpression) != nil
    }

    /// The script's only input is the device, checked to be a `/dev/ttysNNN`
    /// path. It reads each tab's device and nothing else, never its contents.
    /// It runs once the terminal is in front: finishing activation brings back
    /// whichever window was key last, which would undo a raise made before.
    static func selectionScript(device: String, terminal: ScriptableTerminal) -> String {
        switch terminal {
        case .terminal:
            return """
            if application id "com.apple.Terminal" is not running then return false
            with timeout of 3 seconds
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        try
                            repeat with t in tabs of w
                                if tty of t is "\(device)" then
                                    if miniaturized of w then set miniaturized of w to false
                                    set selected of t to true
                                    set index of w to 1
                                    return true
                                end if
                            end repeat
                        end try
                    end repeat
                end tell
            end timeout
            return false
            """
        case .iTerm:
            return """
            if application id "com.googlecode.iterm2" is not running then return false
            with timeout of 3 seconds
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        try
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if tty of s is "\(device)" then
                                        select w
                                        select t
                                        select s
                                        return true
                                    end if
                                end repeat
                            end repeat
                        end try
                    end repeat
                end tell
            end timeout
            return false
            """
        }
    }

    // MARK: - Doing it

    /// Brings forward the session running as `pid`. False when nothing can be:
    /// the process has gone, or no app hosts it.
    @discardableResult
    static func focus(pid: pid_t) -> Bool {
        switch plan(for: pid, in: .system) {
        case .selectTab(let device, let terminal, let app):
            selectTab(device, in: terminal, app: app)
            return true
        case .bringForward(let app):
            return bringForward(pid: app)
        case .nothing:
            return false
        }
    }

    /// Brings a provider's own app forward, opening it first where that is its
    /// job. False when it neither runs nor is to be opened.
    @discardableResult
    static func open(_ target: ProviderApp) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID)
            .first(where: { !$0.isTerminated }) {
            bringForward(app)
            return true
        }
        guard target.opens, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else {
            return false
        }
        openApplication(at: url)
        return true
    }

    private static let automation = DispatchQueue(label: "local.brim.session-focus", qos: .userInitiated)

    private static func selectTab(_ device: String, in terminal: ScriptableTerminal, app: pid_t) {
        // Asking can put up macOS's consent prompt, which must not freeze the notch.
        automation.async {
            let allowed = mayScript(terminal)
            DispatchQueue.main.async {
                guard let running = NSRunningApplication(processIdentifier: app), !running.isTerminated else { return }
                bringForward(running) {
                    if allowed { _ = runSelection(device, in: terminal) }
                }
            }
        }
    }

    /// Whether macOS lets Brim script `terminal`, asking you the first time.
    /// Blocks while the prompt is up, so never called on the main thread.
    private static func mayScript(_ terminal: ScriptableTerminal) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: terminal.rawValue)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard),
                                                     AEEventID(typeWildCard), true) == OSStatus(noErr)
    }

    /// Selects the tab on `device`, raising its window. False if no tab has
    /// it, or the terminal would not answer.
    private static func runSelection(_ device: String, in terminal: ScriptableTerminal) -> Bool {
        guard isTerminalDevice(device),
              let script = NSAppleScript(source: selectionScript(device: device, terminal: terminal)) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    @discardableResult
    static func bringForward(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        bringForward(app)
        return true
    }

    /// Asks the app to come forward, then runs `then` once it is in front, or
    /// has had long enough to get there. macOS can turn down an activation
    /// asked for by an app that isn't active itself, which Brim never is, so if
    /// the app isn't in front shortly LaunchServices is asked, as the Dock would be.
    private static func bringForward(_ app: NSRunningApplication, then: (() -> Void)? = nil) {
        if app.isHidden { app.unhide() }
        app.activate()
        awaitFront(app.processIdentifier, bundleURL: app.bundleURL, since: Date(), askedLaunchServices: false, then: then)
    }

    private static func awaitFront(_ pid: pid_t, bundleURL: URL?, since start: Date, askedLaunchServices: Bool,
                                   then: (() -> Void)?) {
        let waited = Date().timeIntervalSince(start)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid || waited > 1.5 {
            then?()
            return
        }
        var asked = askedLaunchServices
        if !asked, waited >= 0.3, let bundleURL {
            openApplication(at: bundleURL)
            asked = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            awaitFront(pid, bundleURL: bundleURL, since: start, askedLaunchServices: asked, then: then)
        }
    }

    private static func openApplication(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The kernel's record of a process: parent, short name, controlling
    /// terminal. Read at the click, never kept.
    static func kernelEntry(_ pid: pid_t) -> ProcessEntry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var device: String?
        let terminal = info.kp_eproc.e_tdev
        if terminal != -1, let raw = devname(terminal, S_IFCHR) {
            device = "/dev/" + String(cString: raw)
        }
        return ProcessEntry(parent: parent > 1 ? parent : nil, name: name, device: device)
    }
}

extension SessionFocus.Processes {
    static var system: SessionFocus.Processes {
        SessionFocus.Processes(
            isRunning: SessionFocus.isRunning,
            entry: SessionFocus.kernelEntry,
            regularApp: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else {
                    return nil
                }
                return app.bundleIdentifier ?? ""
            },
            runningApp: { id in
                NSRunningApplication.runningApplications(withBundleIdentifier: id).first { !$0.isTerminated }?.processIdentifier
            })
    }
}
