// Downloads in progress, for the notch: subscribes to the progress that
// browsers publish for files in ~/Downloads (the same progress Finder shows
// on a downloading file's icon) and shows a ring beside the camera while a
// download runs longer than a moment, then a short "Downloaded" check.
import AppKit
import SwiftUI

@MainActor
final class Downloads {
    private var subscriber: Any?
    private var active: [ObjectIdentifier: (progress: Progress, started: Date)] = [:]
    private var timer: Timer?

    func start() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            let key = ObjectIdentifier(progress)
            DispatchQueue.main.async { self?.added(progress, key) }
            return { DispatchQueue.main.async { self?.removed(progress, key) } }
        }
    }

    private func added(_ progress: Progress, _ key: ObjectIdentifier) {
        active[key] = (progress, Date())
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    private func removed(_ progress: Progress, _ key: ObjectIdentifier) {
        guard let entry = active.removeValue(forKey: key) else { return }
        let shown = Date().timeIntervalSince(entry.started) > 1.5
        if active.isEmpty { timer?.invalidate(); timer = nil; Notch.shared.clear("download") }
        guard shown, !progress.isCancelled else { return }
        Notch.shared.post(NotchAlert(id: "download-done", icon: .symbol("arrow.down.circle.fill", .white),
                                     trailing: .done, title: "Downloaded",
                                     subtitle: Self.name(progress), duration: 2.5,
                                     action: { if let url = progress.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }))
    }

    /// Shows the oldest running download once it has run 1.5 s (quick ones never show).
    private func update() {
        guard let (progress, started) = active.values.min(by: { $0.started < $1.started }),
              Date().timeIntervalSince(started) > 1.5 else { return }
        let fraction = progress.fractionCompleted.isFinite ? progress.fractionCompleted : 0
        var detail = "\(Int(fraction * 100))%"
        if progress.totalUnitCount > 0, progress.kind == .file || progress.fileTotalCount == nil {
            let f = ByteCountFormatter()
            detail += " · " + f.string(fromByteCount: progress.completedUnitCount) + " of " + f.string(fromByteCount: progress.totalUnitCount)
        }
        Notch.shared.post(NotchAlert(id: "download", icon: .symbol("arrow.down.circle.fill", .white, .dropping), trailing: .ring(fraction, .white),
                                     title: Self.name(progress), subtitle: detail, duration: 0))
    }

    private static func name(_ progress: Progress) -> String {
        progress.fileURL?.lastPathComponent.replacingOccurrences(of: ".download", with: "")
            .replacingOccurrences(of: ".crdownload", with: "") ?? "Download"
    }
}
