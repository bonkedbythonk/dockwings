// Dock bar: keeps the Dock stretched edge to edge as apps open and quit.
// The Dock is as long as its tiles; with the `Bar` key DockWings pads it with
// blank spacer tiles (after Finder, and after the separator) so it reaches
// the widest macOS allows. When an app opens or quits, it counts the tiles
// again and, if the spacers no longer fill the width (or overfill it, which
// shrinks every icon), rewrites the two spacer runs in com.apple.dock and
// restarts the Dock (a moment of flicker). Only spacer tiles are touched.
import AppKit

@MainActor
enum DockSpacers {
    private static var pending: DispatchWorkItem?
    private static var lastRestart = Date.distantPast

    static func start() {
        guard Config.bar else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.activationPolicy == .regular else { return }
                MainActor.assumeIsolated { schedule() }
            }
        }
        schedule()
    }

    /// Waits for the Dock to show the change (and for a burst of launches
    /// to settle) before counting.
    private static func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { adjust() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private static func adjust() {
        guard let screen = NSScreen.main, let items = DockGeometry.items(),
              let prefs = UserDefaults(suiteName: "com.apple.dock") else { return }
        // Restarting again within seconds would be a flicker storm.
        guard Date().timeIntervalSince(lastRestart) > 8 else { schedule(); return }
        let tile = CGFloat(prefs.double(forKey: "tilesize") > 0 ? prefs.double(forKey: "tilesize") : 57)
        // A tile's slot at full size is about 4 pt wider than the icon; the
        // separator about 27 pt. macOS keeps the Dock about 42 pt from each
        // screen edge at most (measured on macOS 27).
        let slot = tile + 4, separator: CGFloat = 27
        let room = screen.frame.width - 84
        var others: CGFloat = 0
        var spacers = 0
        for item in items {
            switch item.subrole {
            case "AXSpacerDockItem": spacers += 1
            case "AXSeparatorDockItem": others += separator
            default: others += slot
            }
        }
        let wanted = max(0, Int(((room - others) / slot).rounded(.down)))
        guard wanted != spacers else { return }
        // Half after Finder, half after the separator (the left gets the odd one).
        rewrite(left: (wanted + 1) / 2, right: wanted / 2)
    }

    /// Sets the number of spacers in the leading run of persistent-apps and
    /// in persistent-others, keeping every other tile as it is.
    private static func rewrite(left: Int, right: Int) {
        let id = "com.apple.dock" as CFString
        guard var apps = CFPreferencesCopyAppValue("persistent-apps" as CFString, id) as? [[String: Any]] else { return }
        let others = CFPreferencesCopyAppValue("persistent-others" as CFString, id) as? [[String: Any]] ?? []
        func isSpacer(_ t: [String: Any]) -> Bool { (t["tile-type"] as? String) == "spacer-tile" }
        let spacer: [String: Any] = ["tile-type": "spacer-tile", "tile-data": [String: Any]()]
        let lead = apps.prefix { isSpacer($0) }.count
        apps.removeFirst(lead)
        apps.insert(contentsOf: Array(repeating: spacer, count: left), at: 0)
        let keptOthers = others.filter { !isSpacer($0) }
        CFPreferencesSetAppValue("persistent-apps" as CFString, apps as CFArray, id)
        CFPreferencesSetAppValue("persistent-others" as CFString, (Array(repeating: spacer, count: right) + keptOthers) as CFArray, id)
        CFPreferencesAppSynchronize(id)
        lastRestart = Date()
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["Dock"]
        try? kill.run()
    }
}
