// Decides, per widget, whether its text is drawn dark or light by looking at
// what is behind it (one wing can sit half over a bright window and half over
// a dark one). Each wing as a whole gets a value too, for its page dots and
// for widgets not measured yet. Really bright behind a widget: dark text. Anything else, mid tones
// included: light text with a shadow, a heavier one when part of what is
// behind the widget is bright (half over a white window, half over black).
// With Screen Recording allowed it reads the real pixels behind the wings
// (DockWings' own windows left out), every few seconds, so rotating wallpapers
// and windows behind the wings count. Without it, it reads the wallpaper file
// (NSWorkspace's desktop image); a wallpaper folder or dynamic wallpaper then
// keeps light text.
import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
final class Ink: ObservableObject {
    static let shared = Ink()
    /// Keyed by widget id, and by `Ink.key(side)` for a whole wing.
    @Published private(set) var dark: [String: Bool] = [:]
    /// Widgets with light text over a background that is partly bright.
    @Published private(set) var mixed: Set<String> = []

    static func key(_ side: Side) -> String { side == .left ? "wing.left" : "wing.right" }

    private var lastKey = ""
    private var cache: (url: URL, image: CGImage)?
    /// A capture was refused although access looked granted (each try shows
    /// macOS's permission dialog): use the wallpaper file until relaunch.
    private var refused = false

    /// `regions` are each wing's and each widget's area in screen coordinates
    /// (AppKit, origin bottom-left); `screen` is the screen they're on.
    func update(regions: [String: NSRect], screen: NSScreen) {
        if Config.backdrop == nil, !refused, CGPreflightScreenCaptureAccess() {
            updateLive(regions: regions, screen: screen)
            return
        }
        // Test aid: a -Backdrop image stands in for the wallpaper, stretched
        // over the bottom 260 pt like the backdrop window.
        let backdrop = Config.backdrop.map { URL(fileURLWithPath: $0) }
        guard let url = backdrop ?? NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        let area = backdrop == nil ? screen.frame : NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 260)
        let key = url.path + regions.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value)" }.joined()
            + "\((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)"
        guard key != lastKey else { return }
        lastKey = key
        guard let image = loadImage(url) else {
            if dark != [:] { dark = [:] }
            return
        }
        var result: [String: Bool] = [:]
        var uneven: Set<String> = []
        for (id, region) in regions {
            guard let stats = Self.stats(image, region: region, area: area, stretched: backdrop != nil) else { continue }
            // Really bright behind the widget: dark text. Mid tones keep white
            // text with its shadow, which reads better there.
            result[id] = stats.mean > 0.75
            if stats.mean <= 0.75, stats.spread > 0.25 { uneven.insert(id) }
        }
        if result != dark { dark = result }
        if uneven != mixed { mixed = uneven }
    }

    private var lastLive = Date.distantPast
    private var capturing = false
    /// What to capture (the display, without DockWings' windows); looked up
    /// again only every minute or when the display changes, since asking
    /// macOS for it is the costly part.
    private var filter: (display: CGDirectDisplayID?, filter: SCContentFilter, date: Date)?

    /// Reads the real pixels behind both wings in one small capture, at most
    /// every 4 s. Hysteresis keeps the text from flipping on mid-grey.
    private func updateLive(regions: [String: NSRect], screen: NSScreen) {
        guard !capturing, Date().timeIntervalSince(lastLive) > 4, !regions.isEmpty else { return }
        lastLive = Date()
        capturing = true
        let strip = regions.values.reduce(NSRect.null) { $0.union($1) }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let screenFrame = screen.frame
        Task {
            defer { capturing = false }
            let filter: SCContentFilter
            if let cached = self.filter, cached.display == displayID, Date().timeIntervalSince(cached.date) < 60 {
                filter = cached.filter
            } else {
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
                    self.refused = true
                    return
                }
                guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
                else { return }
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                self.filter = (displayID, filter, Date())
            }
            let config = SCStreamConfiguration()
            // Display points, origin top-left.
            config.sourceRect = CGRect(x: strip.minX - screenFrame.minX, y: screenFrame.maxY - strip.maxY,
                                       width: strip.width, height: strip.height)
            config.width = max(8, Int(strip.width / 4))
            config.height = max(4, Int(strip.height / 4))
            config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return }
            var result: [String: Bool] = [:]
            var uneven: Set<String> = []
            for (id, region) in regions {
                // The region's part of the strip, in image pixels (top-left origin).
                let sx = Double(image.width) / strip.width, sy = Double(image.height) / strip.height
                let crop = CGRect(x: (region.minX - strip.minX) * sx, y: (strip.maxY - region.maxY) * sy,
                                  width: region.width * sx, height: region.height * sy).integral
                guard crop.width >= 1, crop.height >= 1, let part = image.cropping(to: crop), let (mean, bright) = Self.mean(part) else { continue }
                let was = dark[id] ?? false
                result[id] = was ? mean > 0.7 : mean > 0.75
                // Light text where a fifth or more of the area is bright.
                if result[id] == false, bright > (mixed.contains(id) ? 0.15 : 0.2) { uneven.insert(id) }
            }
            if result != dark || uneven != mixed {
                withAnimation(.smooth(duration: 0.6)) { dark = result; mixed = uneven }
            }
        }
    }

    /// Mean luminance and the share of bright pixels (0...1).
    private static func mean(_ image: CGImage) -> (Double, Double)? {
        let w = 32, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let n = Double(w * h)
        return (pixels.reduce(0) { $0 + Double($1) } / n / 255, Double(pixels.filter { $0 > 204 }.count) / n)
    }

    private func loadImage(_ url: URL) -> CGImage? {
        if let cache, cache.url == url { return cache.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 800,
              ] as CFDictionary)
        else { return nil }
        cache = (url, image)
        return image
    }

    /// Mean luminance and its standard deviation (0...1) of the part of the
    /// image under `region`. The image covers `area`: filled and cropped to
    /// keep its aspect (the macOS wallpaper default), or stretched.
    private static func stats(_ image: CGImage, region: NSRect, area: NSRect, stretched: Bool) -> (mean: Double, spread: Double)? {
        let iw = Double(image.width), ih = Double(image.height)
        let fill = max(iw / area.width, ih / area.height)
        let sx = stretched ? iw / area.width : fill, sy = stretched ? ih / area.height : fill
        let offsetX = (iw - area.width * sx) / 2, offsetY = (ih - area.height * sy) / 2
        // Screen y grows up; image y grows down.
        let x = (region.minX - area.minX) * sx + offsetX
        let y = (area.maxY - region.maxY) * sy + offsetY
        let crop = CGRect(x: x, y: y, width: region.width * sx, height: region.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
        guard crop.width > 4, crop.height > 4, let part = image.cropping(to: crop) else { return nil }

        // Draw into a small grey buffer and measure.
        let w = 64, h = max(4, Int(64 * crop.height / crop.width))
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
        let values = pixels.map { Double($0) / 255 }
        let mean = values.reduce(0, +) / Double(values.count)
        let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        return (mean, spread)
    }
}
