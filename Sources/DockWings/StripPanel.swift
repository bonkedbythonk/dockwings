// A borderless, transparent, non-activating floating panel covering one fixed
// area next to the Dock. The window itself never animates or resizes while in
// use; its SwiftUI content appears, morphs and disappears inside it. Clicks
// pass through while the panel shows nothing (`passThrough`).
import AppKit
import SwiftUI

final class StripPanel: NSPanel {
    init<V: View>(_ root: V) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 70),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Just above the Dock (20) but below system overlays like the
        // screenshot thumbnail (24), so those always cover the wings and stay
        // clickable. Exactly the Dock's level kept the panels from joining
        // other desktops.
        level = NSWindow.Level(rawValue: 23)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let content = root
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu {
                Button("Settings…") { NotificationCenter.default.post(name: .openSettings, object: nil) }
                Button("Quit DockWings") { NSApp.terminate(nil) }
            }
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }


    /// Moves the area; glides when it was already on screen (the Dock grew or
    /// shrank), jumps otherwise.
    func setRegion(_ frame: NSRect) {
        // A panel hidden earlier (Dock briefly unreadable) must come back
        // even when its place hasn't changed.
        if alphaValue == 0 { alphaValue = 1 }
        if !isVisible {
            setFrame(frame, display: true)
            orderFrontRegardless()
            return
        }
        guard frame != self.frame else { return }
        if isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
            orderFrontRegardless()
        }
    }

    /// Hides without leaving the screen: a window that is ordered out and
    /// back in afterwards stays on the current desktop only.
    func conceal() {
        alphaValue = 0
        ignoresMouseEvents = true
    }

    var passThrough: Bool {
        get { ignoresMouseEvents }
        set { if ignoresMouseEvents != newValue { ignoresMouseEvents = newValue } }
    }
}
