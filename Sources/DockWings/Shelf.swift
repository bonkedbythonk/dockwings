// File shelf, a widget in the left wing: shows while a file is being
// dragged, holds dropped files, and lets them be dragged out again. Stays
// while it holds anything. `dragging` is set by AppDelegate's drag watcher.
import SwiftUI

@MainActor
final class Shelf: ObservableObject {
    @Published var items: [URL] = []
    @Published var dragging = false

    var visible: Bool { dragging || !items.isEmpty }

    init() {
        guard let demo = Config.demo else { return }
        if demo == "a" {
            let dir = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")
            items = ["Big Sur.heic", "Catalina.heic", "Big Sur Graphic Light.heic"].map { dir.appendingPathComponent($0) }
        } else if demo == "b" {
            dragging = true
        }
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) { items.append(url) }
    }
}

/// The shelf as a widget in the left wing: a dashed drop spot while you drag
/// a file, then the files it holds (drag them out again, right-click to
/// remove, x to clear).
struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            if shelf.items.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(ink(targeted ? 0.95 : 0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 17, weight: .medium))
                }
                .frame(width: 44, height: 44)
                Lines(title: "Drop to keep", subtitle: "File shelf", maxWidth: 110)
            } else {
                ForEach(shelf.items.suffix(4), id: \.self) { url in
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 40, height: 40)
                        .help(url.lastPathComponent)
                        .draggable(url)
                        .contextMenu { Button("Remove") { shelf.items.removeAll { $0 == url } } }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if shelf.items.count > 4 {
                    Text("+\(shelf.items.count - 4)").font(.system(size: 12, weight: .semibold)).foregroundStyle(ink(0.6))
                }
                Button { shelf.items.removeAll() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ink(0.6))
                .help("Clear shelf")
            }
        }
        .padding(6)
        .contentShape(Rectangle())
        .scaleEffect(targeted ? 1.06 : 1, anchor: .bottom)
        .animation(.spring(duration: 0.25, bounce: 0.25), value: targeted)
        .animation(.smooth(duration: 0.3), value: shelf.items)
        .dropDestination(for: URL.self) { urls, _ in
            shelf.add(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}
