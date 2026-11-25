// Finds where the Dock is on screen. Reads the Dock's icon list through the
// Accessibility API; without that permission it guesses from the screen's
// visible frame. Returned rects are in AppKit coordinates (origin bottom-left).
import AppKit
import ApplicationServices

enum DockGeometry {
    /// The Dock's icon area and its screen, or nil when the panels have no
    /// fixed place: Dock on the left or right, auto-hidden, or not found.
    static func usableDock() -> (rect: NSRect, screen: NSScreen)? {
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        if let side = prefs?.string(forKey: "orientation"), side != "bottom" { return nil }
        guard let rect = axFrame() ?? guessedFrame(),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(rect.insetBy(dx: 1, dy: 1)) }),
              screen.visibleFrame.minY - screen.frame.minY > 20
        else { return nil }
        return (rect, screen)
    }

    /// Bar mode: where the wings sit. Each side is a span of spacer runs,
    /// split at the widest stretch of apps (the Dock's own app list); apps
    /// dragged in among a side's spacers are holes the widgets go around.
    /// Spans and holes are screen rects.
    static func spacerSides() -> (left: NSRect, right: NSRect, leftHoles: [NSRect], rightHoles: [NSRect])? {
        guard let runs = spacerRuns(), runs.count >= 2 else { return nil }
        // The widest gap between neighbouring runs is the main app list.
        let split = (1..<runs.count).max { runs[$0].minX - runs[$0 - 1].maxX < runs[$1].minX - runs[$1 - 1].maxX }!
        let left = Array(runs[..<split]), right = Array(runs[split...])
        func holes(_ side: [NSRect]) -> [NSRect] {
            zip(side, side.dropFirst()).map { NSRect(x: $0.maxX, y: $0.minY, width: $1.minX - $0.maxX, height: $0.height) }
        }
        return (left.reduce(left[0]) { $0.union($1) }, right.reduce(right[0]) { $0.union($1) }, holes(left), holes(right))
    }

    /// Every item in the Dock's list: its Accessibility subrole and width.
    static func items() -> [(subrole: String, width: CGFloat)]? {
        guard let list = dockList(), let items = copy(list, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        return items.map { ((copy($0, kAXSubroleAttribute) as? String) ?? "", frame(of: $0)?.width ?? 0) }
    }

    /// Every run of blank spacer tiles in the Dock, left to right.
    private static func spacerRuns() -> [NSRect]? {
        guard let list = dockList(), let items = copy(list, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        var runs: [NSRect] = []
        var inRun = false
        for item in items {
            guard (copy(item, kAXSubroleAttribute) as? String) == "AXSpacerDockItem", let f = frame(of: item) else { inRun = false; continue }
            if inRun { runs[runs.count - 1] = runs[runs.count - 1].union(f) } else { runs.append(f) }
            inRun = true
        }
        return runs
    }

    private static func axFrame() -> NSRect? {
        dockList().flatMap(frame(of:))
    }

    private static func dockList() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        return (copy(app, kAXChildrenAttribute) as? [AXUIElement])?
            .first { (copy($0, kAXRoleAttribute) as? String) == kAXListRole }
    }

    private static func frame(of element: AXUIElement) -> NSRect? {
        guard let posValue = copy(element, kAXPositionAttribute),
              let sizeValue = copy(element, kAXSizeAttribute)
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        // AX uses top-left origin of the primary screen; flip to AppKit.
        guard let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: pos.x, y: primary.frame.height - pos.y - size.height, width: size.width, height: size.height)
    }

    private static func guessedFrame() -> NSRect? {
        guard let screen = NSScreen.main else { return nil }
        let height = screen.visibleFrame.minY - screen.frame.minY
        guard height > 20 else { return nil }
        let width = screen.frame.width * 0.45
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.minY, width: width, height: height)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
