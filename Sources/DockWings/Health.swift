// Mac health widget: shows only when something is wrong. One process using
// most of a core (80% or more) for a minute, memory pressure at critical,
// under 10 GB of disk left, or macOS reporting the Mac as hot (thermal state
// serious or critical). Worst one wins; "Ignore" hides it until the problem
// changes. CPU use comes from each process's CPU time (proc_pid_rusage) every
// 5 s, in process and cheap; processes of other users (root daemons) can't be
// read and are left out. Also feeds the Mac widget: battery time to 20% and
// die temperature (Thermal), read every 30 s, and the busiest processes for
// its drawer, kept only while that drawer is open. Under 30 min to 20% (or
// below 20%) it asks to charge and the Mac widget moves up. Power changes
// re-read at once.
import AppKit
import Combine
import IOKit.ps
import SwiftUI

@MainActor
final class Health: ObservableObject {
    static let shared = Health()

    struct Issue: Equatable {
        let key: String
        let symbol: String
        let title: String
        let subtitle: String
        let critical: Bool
        var pid: pid_t?
    }

    struct Proc: Identifiable, Equatable {
        let id: pid_t
        let name: String
        let percent: Int
    }

    @Published private(set) var issue: Issue?
    /// Drawer only: busiest processes, hottest die sensor, battery time.
    @Published private(set) var top: [Proc] = []
    @Published private(set) var celsius: Double?
    @Published private(set) var batteryTime: String?
    /// On battery with under 30 min to 20%, or already below 20%.
    @Published private(set) var needsCharge = false

    private var dismissed: String?
    private var lastTimes: [pid_t: UInt64] = [:]
    private var lastSample = Date()
    /// When each process went over the threshold, while it stays over.
    private var busySince: [pid_t: Date] = [:]
    private var hogs: [Proc] = []
    private var lastUsage: [(pid: pid_t, percent: Double)] = []
    private var lowDisk: Int?
    private var tick = 0
    private var live = false
    private var thermal: Thermal?
    private var watchers: [AnyCancellable] = []
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    init() {
        if Config.demo == "a" {
            issue = Issue(key: "demo", symbol: "cpu", title: "Xcode", subtitle: "Using 140% CPU", critical: false)
            top = [Proc(id: 1, name: "Xcode", percent: 140), Proc(id: 2, name: "WindowServer", percent: 18), Proc(id: 3, name: "Safari", percent: 6)]
            celsius = 58
            batteryTime = "3h 40m to 20%"
            return
        }
        sample()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        watchers.append(Drawers.shared.$open.receive(on: RunLoop.main).sink { [weak self] open in
            guard let self else { return }
            live = open == "mac"
            if live { updateTop() }
        })
        thermal = Thermal()
        readStats()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readStats() }
        }
        // Plugged in or unplugged: update at once instead of within 30 s.
        watchers.append(NotificationCenter.default.publisher(for: .powerChanged).receive(on: RunLoop.main).sink { [weak self] _ in
            self?.readStats()
        })
    }

    func ignore() {
        dismissed = issue?.key
        issue = nil
    }

    private func sample() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSample) * 1e9
        lastSample = now
        var times: [pid_t: UInt64] = [:]
        var usage: [(pid: pid_t, percent: Double)] = []
        let own = getpid()
        for pid in Self.allPids() where pid != own {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            let total = info.ri_user_time + info.ri_system_time
            times[pid] = total
            if let before = lastTimes[pid], total >= before, elapsed > 0 {
                usage.append((pid, Double(total - before) * timebase / elapsed * 100))
            }
        }
        lastTimes = times
        usage.sort { $0.percent > $1.percent }

        var since: [pid_t: Date] = [:]
        for entry in usage where entry.percent >= 80 { since[entry.pid] = busySince[entry.pid] ?? now }
        busySince = since
        hogs = usage.filter { since[$0.pid].map { now.timeIntervalSince($0) >= 60 } ?? false }
            .map { Proc(id: $0.pid, name: Self.name($0.pid), percent: Int(($0.percent / 10).rounded()) * 10) }
        lastUsage = usage
        if live { updateTop() }
        if tick % 60 == 0 { checkDisk() }
        tick += 1
        evaluate()
    }

    private func updateTop() {
        let busiest = lastUsage.prefix(5).map { Proc(id: $0.pid, name: Self.name($0.pid), percent: Int($0.percent.rounded())) }
        if busiest != top { top = busiest }
    }

    private func evaluate() {
        var found: [Issue] = []
        if Self.memoryPressure() >= 4 {
            found.append(Issue(key: "memory", symbol: "memorychip", title: "Memory is full", subtitle: "Quit apps you're not using", critical: true))
        }
        let heat = ProcessInfo.processInfo.thermalState
        if heat == .serious || heat == .critical {
            found.append(Issue(key: "heat\(heat.rawValue)", symbol: "thermometer.high", title: "Mac is hot",
                               subtitle: heat == .critical ? "Slowing down to cool" : "Running warm", critical: heat == .critical))
        }
        if let hog = hogs.first {
            found.append(Issue(key: "cpu\(hog.id)", symbol: "cpu", title: hog.name, subtitle: "Using \(hog.percent)% CPU",
                               critical: false, pid: hog.id))
        }
        if let gb = lowDisk {
            found.append(Issue(key: "disk", symbol: "internaldrive", title: "Disk almost full", subtitle: "\(gb) GB left", critical: gb < 3))
        }
        let next = found.sorted { $0.critical && !$1.critical }.first
        if next?.key != dismissed { dismissed = nil }
        let shown = next?.key == dismissed ? nil : next
        if shown != issue { issue = shown }
    }

    private func checkDisk() {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let gb = values?.volumeAvailableCapacityForImportantUsage.map { Int($0 / 1_000_000_000) }
        lowDisk = gb.flatMap { $0 < 10 ? $0 : nil }
    }

    /// Temperature and battery time for the Mac widget. Skipped while the
    /// wings can't be seen.
    private func readStats() {
        guard Presence.shared.visible else { return }
        let peak = thermal?.peak().map { $0.rounded() }
        if peak != celsius { celsius = peak }
        let battery = Self.battery()
        if battery?.text != batteryTime { batteryTime = battery?.text }
        let low = battery?.low ?? false
        if low != needsCharge { needsCharge = low }
    }

    /// "2h 10m until 20%" on battery (or until empty once below 20%), from
    /// macOS's own time-to-empty estimate; nil while charging or estimating.
    /// `low` once under 30 min to 20% or below 20%.
    private static func battery() -> (text: String, low: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let minutes = d[kIOPSTimeToEmptyKey] as? Int, minutes > 0,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let percent = current * 100 / max
            // The estimate drains roughly evenly, so the part above 20% is
            // that share of the time.
            let left = percent > 20 ? minutes * (percent - 20) / percent : minutes
            // Two-digit minutes keep the widget's width steady.
            let text = left >= 60 ? "\(left / 60)h " + String(format: "%02dm", left % 60) : "\(left)m"
            return (text + (percent > 20 ? " to 20%" : " to empty"), percent <= 20 || left < 30)
        }
        return nil
    }

    private static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(found, 0))))
    }

    private static func name(_ pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "Process \(pid)" : name
    }

    /// 1 normal, 2 warning, 4 critical: the level macOS itself acts on.
    private static func memoryPressure() -> Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return level
    }
}

struct HealthView: View {
    @ObservedObject var health: Health

    var body: some View {
        if let issue = health.issue {
            HStack(spacing: 10) {
                if let pid = issue.pid, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 34, height: 34)
                } else {
                    Image(systemName: issue.symbol).font(.system(size: 22, weight: .medium)).frame(width: 34)
                }
                Lines(title: issue.title, subtitle: issue.subtitle, maxWidth: 150)
            }
            .overlay(alignment: .topLeading) {
                Circle().fill(issue.critical ? Color(red: 1, green: 0.42, blue: 0.38) : Color(red: 1, green: 0.72, blue: 0.3))
                    .frame(width: 7, height: 7).offset(x: -3, y: 2)
            }
            .tapAction { Self.openActivityMonitor() }
            .contextMenu {
                if let pid = issue.pid, let app = NSRunningApplication(processIdentifier: pid) {
                    Button("Quit \(issue.title)") { app.terminate() }
                }
                if issue.key == "disk" {
                    Button("Storage Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!) }
                }
                Button("Open Activity Monitor") { Self.openActivityMonitor() }
                Button("Ignore") { health.ignore() }
            }
            .help("Click to open Activity Monitor")
            .id(issue.key)
            .transition(.blurReplace)
        }
    }

    static func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

/// Mac widget: battery time to 20% (or "On power") over the die temperature.
struct MacView: View {
    @ObservedObject var health: Health

    var body: some View {
        Button { Drawers.shared.toggle("mac") } label: {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer").font(.system(size: 20, weight: .medium)).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    if health.needsCharge {
                        // Compact while warning: just the time left, in red.
                        Text(health.batteryTime.map { $0.replacingOccurrences(of: " to 20%", with: "") } ?? "")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.38))
                    } else {
                        Text(health.batteryTime ?? "On power").font(.system(size: 14, weight: .semibold))
                    }
                    if !health.needsCharge, let celsius = health.celsius {
                        Text("\(Int(celsius))°C").font(.system(size: 12)).foregroundStyle(ink(0.6))
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            }
        }
        .buttonStyle(WidgetPress())
        .contextMenu { Button("Open Activity Monitor") { HealthView.openActivityMonitor() } }
    }
}

/// Mac drawer: the busiest processes right now.
struct MacDrawer: View {
    @ObservedObject var health: Health

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(health.top) { proc in
                HStack {
                    Text(proc.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 24)
                    Text("\(proc.percent)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(proc.percent >= 80 ? Color(red: 1, green: 0.72, blue: 0.3) : .secondary)
                }
            }
            if health.top.isEmpty { Text("Measuring...").font(.system(size: 12)).foregroundStyle(.secondary) }
            Button("Open Activity Monitor") { HealthView.openActivityMonitor() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(16)
        .frame(minWidth: 240)
        .card()
    }
}
