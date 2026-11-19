// Phone apps widget: counts down to when the sideloaded iPhone apps stop
// opening. tools/ios-refresh re-signs them (free signing lasts 7 days) and
// writes the Unix time of each app's last refresh to
// ~/Library/Application Support/ios-refresh/<app>; it refreshes after 4 days,
// so the widget only shows once an app has under 3 days left, which means the
// refresh didn't happen. The reason comes from the last line of
// ~/Library/Logs/ios-refresh.log. Red under a day. Clicking runs the refresh
// job now. Checked every minute (a few small file reads).
import AppKit
import SwiftUI

@MainActor
final class PhoneApps: ObservableObject {
    static let shared = PhoneApps()

    struct Status: Equatable {
        /// Apps under 3 days left, soonest first.
        let apps: [String]
        let expires: Date
        let reason: String
    }

    @Published private(set) var status: Status?

    private static let state = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/ios-refresh")
    private static let log = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/ios-refresh.log")
    static let job = "local.ios-refresh"

    init() {
        if Config.demo == "a" {
            status = Status(apps: ["Notes", "Journal"], expires: Date().addingTimeInterval(2 * 86400 + 3600), reason: "Phone not reachable")
            return
        }
        check()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func refreshNow() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "gui/\(getuid())/\(Self.job)"]
        try? task.run()
    }

    private func check() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.state, includingPropertiesForKeys: nil)) ?? []
        // An app's file holds only its last refresh time.
        let expiring = files.compactMap { url -> (name: String, expires: Date)? in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            return (url.lastPathComponent.capitalized, Date(timeIntervalSince1970: seconds + 7 * 86400))
        }
        .filter { $0.expires.timeIntervalSinceNow < 3 * 86400 }
        .sorted { $0.expires < $1.expires }
        let next = expiring.first.map { Status(apps: expiring.map(\.name), expires: $0.expires, reason: Self.reason()) }
        if next != status { status = next }
    }

    /// Why the last run didn't refresh, from the end of its log.
    private static func reason() -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "Not refreshed" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 2048 ? end - 2048 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let last = tail.split(separator: "\n").suffix(4).joined(separator: "\n")
        if last.contains("command not found") { return "Refresh script error" }
        if last.contains("FAILED") { return "Refresh failed" }
        if last.contains("not reachable") { return "Phone not reachable" }
        return "Not refreshed"
    }
}

struct PhoneAppsView: View {
    @ObservedObject var phone: PhoneApps

    var body: some View {
        if let status = phone.status {
            let left = status.expires.timeIntervalSinceNow
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3").font(.system(size: 22, weight: .medium)).frame(width: 30)
                Lines(title: (status.apps.count == 1 ? status.apps[0] : "Phone apps") + " " + Self.left(left),
                      subtitle: status.reason, maxWidth: 160)
            }
            .overlay(alignment: .topLeading) {
                Circle().fill(left < 86400 ? Color(red: 1, green: 0.42, blue: 0.38) : Color(red: 1, green: 0.72, blue: 0.3))
                    .frame(width: 7, height: 7).offset(x: -3, y: 2)
            }
            .tapAction { phone.refreshNow() }
            .contextMenu {
                Button("Refresh Now") { phone.refreshNow() }
                Button("Show Log") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/ios-refresh.log")) }
            }
            .help(status.apps.joined(separator: ", ") + ": click to refresh now")
            .transition(.blurReplace)
        }
    }

    /// "2d left", "17h left", "expired".
    private static func left(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "expired" }
        let hours = Int(seconds / 3600)
        return hours >= 24 ? "\(hours / 24)d left" : "\(max(hours, 1))h left"
    }
}
