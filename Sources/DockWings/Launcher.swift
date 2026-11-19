// Starting at login and restarting after a crash: a plain launch agent,
// ~/Library/LaunchAgents/local.dockwings.login.plist, pointing at this app.
// launchd starts DockWings at login and again within seconds if it ever
// crashes; quitting it normally (exit 0) leaves it quit. (The earlier
// ServiceManagement agent got stuck unable to spawn; it is removed on the way.)
import AppKit
import ServiceManagement

enum Launcher {
    static let label = "local.dockwings.login"
    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isOn: Bool { FileManager.default.fileExists(atPath: plist.path) }
    /// This copy was started by the agent.
    static var underLaunchd: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    /// Turns starting at login (with crash restart) on or off. With it on,
    /// launchd starts its own copy right away.
    static func set(_ on: Bool) {
        try? SMAppService.agent(plistName: "local.dockwings.agent.plist").unregister()
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        // Booting the job out ends its process: when that is us and we are
        // turning it off, just remove the file (launchd forgets it at logout).
        if on || !underLaunchd { launchctl("bootout", "gui/\(getuid())/\(label)") }
        guard on else { try? FileManager.default.removeItem(at: plist); return }
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/DockWings.app/Contents/MacOS/DockWings"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        (agent as NSDictionary).write(to: plist, atomically: true)
        launchctl("bootstrap", "gui/\(getuid())", plist.path)
    }

    /// Run once at launch: the old ServiceManagement agent or plain login
    /// item becomes the launch agent.
    /// True when it moved (launchd's copy is starting up now).
    static func migrate() -> Bool {
        let old = SMAppService.agent(plistName: "local.dockwings.agent.plist").status != .notRegistered
            || SMAppService.mainApp.status == .enabled
        guard old, !isOn else { return false }
        set(true)
        return true
    }

    /// True when this copy was opened by hand (Finder, Spotlight) while the
    /// agent is on: launchd's copy is started (or shown) instead, so the
    /// running DockWings is always the one that gets restarted after a crash.
    /// False (run this copy) when launchd's copy doesn't come up.
    static func handOver(reopen: Bool = true) -> Bool {
        guard isOn, !underLaunchd else { return false }
        let ours = ProcessInfo.processInfo.processIdentifier
        func othersRunning() -> Bool {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .contains { $0.processIdentifier != ours }
        }
        if othersRunning() {
            // Spotlight reopen: ask the running copy to show Settings.
            guard reopen else { return true }
            DistributedNotificationCenter.default().postNotificationName(.init("local.dockwings.reopen"), object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            return true
        }
        launchctl("kickstart", "gui/\(getuid())/\(label)")
        // launchctl reports success even when launchd can't spawn it.
        for _ in 0..<30 {
            if othersRunning() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func launchctl(_ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }
}
