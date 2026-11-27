// Dock bar: keeps the Dock stretched edge to edge as apps open and quit.
// The Dock is as long as its tiles; with the `Bar` key DockWings pads it with
// blank spacer tiles (after Finder, and after the separator) so it reaches
// the widest macOS allows. When an app opens or quits, it counts the tiles
// again and, if the spacers no longer fill the width (or overfill it, which
// shrinks every icon), rewrites the two spacer runs in com.apple.dock and
// restarts the Dock (a moment of flicker). Resizing the Dock does the same.
// Only spacer tiles are touched.
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
        // Resizing the Dock (its tile size) changes how many spacers fit.
        var size = tileSize()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = tileSize()
                if now != size { size = now; schedule() }
            }
        }
        schedule()
    }

    private static func tileSize() -> Double {
        let id = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(id)
        return (CFPreferencesCopyAppValue("tilesize" as CFString, id) as? NSNumber)?.doubleValue ?? 0
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
        guard let screen = NSScreen.main, let items = DockGeometry.items() else { return }
        // Restarting again within seconds would be a flicker storm.
        guard Date().timeIntervalSince(lastRestart) > 8 else { schedule(); return }
        let tile = CGFloat(tileSize() > 0 ? tileSize() : 54)
        // macOS keeps the Dock's list at least 68 pt from each screen edge
        // (measured on macOS 27, tile sizes 46 and 54).
        let widest = screen.frame.width - 136
        var spacers = 0, spacerWidth: CGFloat = 0
        for item in items where item.subrole == "AXSpacerDockItem" { spacers += 1; spacerWidth = item.width }
        guard spacerWidth > 0, let list = DockGeometry.usableDock()?.rect.width else { return }
        // A tile's slot at its set size (measured: 48 pt at 46, 58 pt at 54).
        // When the Dock overflows, macOS shrinks every tile by the same factor.
        let slot = 1.25 * tile - 9.5
        let shrink = min(1, spacerWidth / slot)
        let wanted: Int
        if list < widest - 1 {
            // Room left: the real tile width says how many more fit.
            wanted = spacers + Int(((widest - list) / spacerWidth).rounded(.down))
        } else if shrink < 0.97 {
            // Overflowing: drop enough to bring the tiles back to full size.
            wanted = max(0, spacers - Int(((list / shrink - widest) / slot).rounded(.up)))
        } else {
            return
        }
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
        // Measure again once the new Dock is up; the first count can be off by one.
        schedule()
    }
}
