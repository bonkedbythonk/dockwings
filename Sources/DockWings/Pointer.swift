// Dock-style magnification for the wings. Reads the Dock's own settings
// (com.apple.dock `magnification`, `tilesize`, `largesize`) so widgets grow by
// the same ratio as Dock icons, or not at all when magnification is off.
// AppDelegate feeds the pointer position; each WingRow asks for a scale.
import AppKit
import SwiftUI

/// Pointer state for one wing, in that wing window's coordinates.
@MainActor
final class WingPointer: ObservableObject {
    @Published var x: CGFloat?
    @Published var boxHeight: CGFloat = 75
    var ratio: CGFloat = 1
    /// Each widget's frame in the wing window, kept by WingRow; used for
    /// magnification and to place drawers.
    var frames: [String: CGRect] = [:]

    /// How far from the pointer a widget still grows a little, in points.
    private let reach: CGFloat = 150

    func scale(at frame: CGRect?) -> CGFloat {
        guard ratio > 1, let x, let frame else { return 1 }
        let distance = abs(x - frame.midX) / reach
        guard distance < 1 else { return 1 }
        return 1 + (ratio - 1) * cos(distance * .pi / 2)
    }
}

@MainActor
final class Pointer {
    let left = WingPointer()
    let right = WingPointer()
    private(set) var headroom: CGFloat = 0
    private var box = NSRect.zero

    /// Called on every layout with the Dock's glass box.
    func update(box: NSRect) {
        self.box = box
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        var ratio: CGFloat = 1
        if prefs?.bool(forKey: "magnification") == true {
            let tile = prefs?.double(forKey: "tilesize") ?? 0
            let large = prefs?.double(forKey: "largesize") ?? 0
            if tile > 0, large > tile { ratio = min(large / tile, 1.5) }
        }
        // Dock bar: room for a widget's attention hop too.
        headroom = ceil(box.height * (ratio - 1)) + (Config.bar ? 12 : 4)
        for wing in [left, right] {
            wing.ratio = ratio
            if wing.boxHeight != box.height { wing.boxHeight = box.height }
        }
    }

    /// Pointer is level with the Dock (where Dock icons would magnify).
    func inBand(_ point: NSPoint) -> Bool {
        point.y >= box.minY - 5 && point.y <= box.maxY + headroom
    }
}
