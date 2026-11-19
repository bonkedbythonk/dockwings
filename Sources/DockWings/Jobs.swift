// Finished-command widget: a zsh hook (docs/zsh-hook.zsh) runs
// `DockWings --notify <exit status> <seconds> <command>` when a command that
// took 20 s or more finishes; main.swift turns that into a distributed
// notification and this shows it for 2 minutes with a check or a cross.
import SwiftUI

enum JobNotice {
    static let name = Notification.Name("local.dockwings.job")
}

@MainActor
final class Jobs: ObservableObject {
    struct Job: Equatable {
        let command: String
        let success: Bool
        let seconds: Int
        let date: Date
    }

    @Published var job: Job?

    init() {
        if Config.demo == "a" {
            job = Job(command: "blender --background render.py", success: true, seconds: 754, date: Date())
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: JobNotice.name, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.show(info) }
        }
    }

    private func show(_ info: [AnyHashable: Any]) {
        let job = Job(command: info["command"] as? String ?? "Command",
                      success: (info["status"] as? String) == "0",
                      seconds: Int(info["seconds"] as? String ?? "") ?? 0,
                      date: Date())
        self.job = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if self.job == job { self.job = nil }
        }
    }
}

struct JobView: View {
    @ObservedObject var jobs: Jobs

    var body: some View {
        if let job = jobs.job {
            HStack(spacing: 10) {
                Image(systemName: job.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white, job.success ? Color(red: 0.2, green: 0.78, blue: 0.4) : Color(red: 0.95, green: 0.3, blue: 0.3))
                    .symbolEffect(.bounce, value: job.date)
                Lines(title: job.command,
                      subtitle: (job.success ? "Done in " : "Failed after ") + Self.duration(job.seconds),
                      maxWidth: 150)
            }
            .tapAction { jobs.job = nil }
            .contextMenu {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.command, forType: .string)
                }
                Button("Dismiss") { jobs.job = nil }
            }
            .help("Click to dismiss")
            .id(job.date)
            .transition(.blurReplace)
        }
    }

    private static func duration(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}
