// Latest file widget: the newest screenshot (from the screenshot folder set
// in com.apple.screencapture, else the Desktop) or download, for 45 seconds
// after it lands. Shows a Quick Look thumbnail you can drag into any app.
// Watches both folders for changes (no polling).
import QuickLookThumbnailing
import SwiftUI

@MainActor
final class Latest: ObservableObject {
    struct Item: Equatable {
        let url: URL
        let date: Date
        let isScreenshot: Bool
    }

    @Published private(set) var item: Item?
    private var dismissed: URL?
    @Published private(set) var thumbnail: NSImage?

    private static let lifetime: TimeInterval = 45
    private let home = FileManager.default.homeDirectoryForCurrentUser

    init() {
        if Config.demo != nil {
            item = Item(url: URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails/Big Sur.heic"),
                        date: Date(), isScreenshot: true)
            thumbnail = NSImage(contentsOf: item!.url)
            return
        }
        for folder in [shotsFolder, home.appendingPathComponent("Downloads")] { watch(folder) }
        scan()
    }

    private var shotsFolder: URL {
        UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? home.appendingPathComponent("Desktop")
    }

    private var sources: [DispatchSourceFileSystemObject] = []

    /// Rescans when a file lands in (or leaves) the folder.
    private func watch(_ folder: URL) {
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scan()
                // A file can finish writing a moment after it appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.scan() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    private func scan() {
        let shots = shotsFolder
        let candidates = [(shots, true), (home.appendingPathComponent("Downloads"), false)].compactMap { folder, isShot in
            newest(in: folder).map { Item(url: $0.0, date: $0.1, isScreenshot: isShot) }
        }
        let fresh = candidates.filter { -$0.date.timeIntervalSinceNow < Self.lifetime && $0.url != dismissed }.max { $0.date < $1.date }
        guard fresh != item else { return }
        item = fresh
        thumbnail = nil
        guard let fresh else { return }
        // Disappear once it's old.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime - (-fresh.date.timeIntervalSinceNow) + 0.2) { [weak self] in
            self?.scan()
        }
        let request = QLThumbnailGenerator.Request(fileAt: fresh.url, size: CGSize(width: 96, height: 96),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            Task { @MainActor in if self.item == fresh { self.thumbnail = image } }
        }
    }

    /// Called when a drag of the item starts: once the button is released away
    /// from where it started (dropped somewhere), the item is done and goes,
    /// and a screenshot file goes to the Trash.
    func dragStarted() {
        let start = NSEvent.mouseLocation
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            let end = NSEvent.mouseLocation
            guard hypot(end.x - start.x, end.y - start.y) > 60 else { return }
            Task { @MainActor in
                // A screenshot dropped somewhere is done with: it goes to the
                // Trash (if the drop moved it, it is already gone).
                if let item = self?.item, item.isScreenshot, FileManager.default.fileExists(atPath: item.url.path) {
                    try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                }
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissed = item?.url
        item = nil
    }

    private func newest(in folder: URL) -> (URL, Date)? {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return nil }
        return files.compactMap { url -> (URL, Date)? in
            guard !["crdownload", "download", "part"].contains(url.pathExtension),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let date = values.creationDate else { return nil }
            return (url, date)
        }.max { $0.1 < $1.1 }
    }
}

struct LatestView: View {
    @ObservedObject var latest: Latest

    var body: some View {
        if let item = latest.item {
            HStack(spacing: 10) {
                Tile(side: 44) {
                    if let thumb = latest.thumbnail {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().padding(4)
                    }
                }
                Lines(title: item.url.lastPathComponent,
                      subtitle: (item.isScreenshot ? "Screenshot · " : "Download · ") + ago(item.date),
                      maxWidth: 130)
            }
            .tapAction { NSWorkspace.shared.open(item.url) }
            .onDrag {
                latest.dragStarted()
                return NSItemProvider(object: item.url as NSURL)
            }
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Button("Dismiss") { latest.dismiss() }
            }
            .help("Click to open, drag into any app")
            .id(item.url)
            .transition(.blurReplace)
        }
    }
}
