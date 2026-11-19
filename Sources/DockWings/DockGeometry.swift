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

    private static func axFrame() -> NSRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let children = copy(app, kAXChildrenAttribute) as? [AXUIElement],
              let list = children.first(where: { (copy($0, kAXRoleAttribute) as? String) == kAXListRole }),
              let posValue = copy(list, kAXPositionAttribute),
              let sizeValue = copy(list, kAXSizeAttribute)
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
