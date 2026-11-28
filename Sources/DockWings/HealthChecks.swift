// The slower checks behind the Mac health widget (Health.swift), each a plain
// function that may run off the main thread:
// - apps not answering: an Accessibility query with a 1 s timeout per
//   regular app; "cannot complete" means its main thread is stuck;
// - memory per app: each process's footprint, helpers counted to the app
//   that launched them (a browser's renderers);
// - what keeps the Mac awake: power assertions that stop idle sleep, by process;
// - forgotten dev servers: TCP ports your own command-line processes listen
//   on (`lsof`), with the folder they run in and since when;
// - uncommitted work: git repositories under ~/Documents/randomcode whose
//   changed files haven't been touched for a day (Health only names ones
//   worked on in the last two weeks; older ones are on purpose).
// System processes (/System, /usr) and app bundles don't count as servers or
// sleep blockers worth naming.
import AppKit
import ApplicationServices
import IOKit.pwr_mgt

enum HealthChecks {
    struct Server: Equatable {
        let pid: pid_t
        let port: Int
        let command: String
        let folder: String?
        let started: Date
    }

    struct Repo: Equatable {
        let path: String
        let changed: Int
        let untouched: TimeInterval
    }

    /// Apps whose main thread doesn't answer, and the ones that did.
    nonisolated static func responsiveness(_ pids: [pid_t]) -> (stuck: Set<pid_t>, answered: Set<pid_t>) {
        var stuck = Set<pid_t>(), answered = Set<pid_t>()
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &value)
            if result == .cannotComplete { stuck.insert(pid) } else if result == .success { answered.insert(pid) }
        }
        return (stuck, answered)
    }

    /// Memory footprint in bytes per app (helpers added to their app's pid),
    /// for processes over 100 MB.
    nonisolated static func memoryByApp(_ pids: [pid_t]) -> [pid_t: UInt64] {
        var total: [pid_t: UInt64] = [:]
        for pid in pids {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0, info.ri_phys_footprint > 100_000_000 else { continue }
            total[owner(of: pid), default: 0] += info.ri_phys_footprint
        }
        return total
    }

    /// The regular app a process belongs to (itself, or the app up its
    /// parent chain), else the process itself.
    nonisolated static func owner(of pid: pid_t, levels: Int = 4) -> pid_t {
        var current = pid
        for _ in 0..<levels {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return current }
            guard let parent = bsd(current).map({ pid_t($0.pbi_ppid) }), parent > 1 else { break }
            current = parent
        }
        return pid
    }

    /// Processes holding an assertion that stops idle sleep (screen or
    /// system), with the assertion's name. Music players and system
    /// processes are left out.
    nonisolated static func sleepBlockers() -> [pid_t: String] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byPid = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [:] }
        let blocking: Set<String> = ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "NoDisplaySleepAssertion", "NoIdleSleepAssertion"]
        // Players, and Claude (its keep-awake setting is on purpose).
        let players: Set<String> = ["mpv", "MusicSample", "Music", "Spotify", "Tide", "Kodi", "IINA", "VLC", "Claude"]
        var out: [pid_t: String] = [:]
        let own = getpid()
        for (key, list) in byPid {
            let pid = key.int32Value
            guard pid != own, !isSystem(pid), !players.contains(name(pid)),
                  let hold = list.first(where: { blocking.contains($0["AssertType"] as? String ?? "") }) else { continue }
            out[pid] = hold["AssertName"] as? String ?? ""
        }
        return out
    }

    /// TCP ports your own command-line processes listen on (lowest port per
    /// process).
    nonisolated static func servers() -> [Server] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-u", "\(getuid())", "-Fpcn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        var ports: [pid_t: (command: String, port: Int)] = [:]
        var pid: pid_t = 0, command = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = pid_t(value) ?? 0
            case "c": command = value
            case "n":
                guard let port = Int(value.split(separator: ":").last ?? ""), pid > 0 else { continue }
                if port < ports[pid]?.port ?? .max { ports[pid] = (command, port) }
            default: break
            }
        }
        return ports.compactMap { pid, entry in
            // Started from an app (a terminal, an editor, Claude); one launchd
            // started is a service on purpose (brew services).
            guard !isSystem(pid), !isAppBundle(pid), let info = bsd(pid), owner(of: pid, levels: 8) != pid else { return nil }
            return Server(pid: pid, port: entry.port, command: entry.command, folder: folder(of: pid),
                          started: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)))
        }
    }

    /// Repositories under ~/Documents/randomcode (four levels down at most)
    /// with uncommitted changes, and how long since a changed file was touched.
    nonisolated static func staleRepos() -> [Repo] {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/randomcode")
        var repos: [URL] = []
        let skip: Set<String> = ["node_modules", ".build", "build", "DerivedData", "Packages", ".venv"]
        func walk(_ dir: URL, _ depth: Int) {
            guard depth <= 4, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            if items.contains(where: { $0.lastPathComponent == ".git" }) { repos.append(dir); return }
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !item.lastPathComponent.hasPrefix(".") && !skip.contains(item.lastPathComponent) {
                walk(item, depth + 1)
            }
        }
        walk(root, 0)
        return repos.compactMap(status)
    }

    /// One repository's uncommitted changes, or nil when it's clean.
    nonisolated static func status(_ repo: URL) -> Repo? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", repo.path, "status", "--porcelain", "-z", "--untracked-files=normal"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        // Entries are "XY path"; a rename is followed by its old path.
        let entries = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { $0.count > 3 && $0.dropFirst(2).first == " " }
        guard !entries.isEmpty else { return nil }
        // A new folder is one entry ("dir/"): the newest visible file inside
        // counts (not folder dates, not a nested clone's .git).
        let key: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let newest = entries.flatMap { entry -> [Date] in
            let file = repo.appendingPathComponent(String(entry.dropFirst(3)))
            guard entry.hasSuffix("/") else { return [try? file.resourceValues(forKeys: key).contentModificationDate].compactMap { $0 } }
            let inside = FileManager.default.enumerator(at: file, includingPropertiesForKeys: Array(key), options: .skipsHiddenFiles)?.allObjects as? [URL] ?? []
            return inside.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: key), values.isRegularFile == true else { return nil }
                return values.contentModificationDate
            }
        }.max() ?? .distantPast
        return Repo(path: repo.path, changed: entries.count, untouched: Date().timeIntervalSince(newest))
    }

    // MARK: Process facts

    nonisolated static func name(_ pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }

    nonisolated static func path(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }

    nonisolated static func isSystem(_ pid: pid_t) -> Bool {
        let p = path(pid)
        return p.isEmpty || p.hasPrefix("/System/") || p.hasPrefix("/usr/") || p.hasPrefix("/sbin/") || p.hasPrefix("/Library/Apple/")
    }

    nonisolated static func isAppBundle(_ pid: pid_t) -> Bool {
        path(pid).contains(".app/")
    }

    nonisolated static func bsd(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 ? info : nil
    }

    /// The folder a process runs in (its working directory).
    nonisolated static func folder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty || path == "/" ? nil : path
    }
}
