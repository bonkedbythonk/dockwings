// Batteries widget: the Mac's own battery (IOKit power sources) and connected
// Bluetooth devices such as AirPods, mice and keyboards (from
// `system_profiler SPBluetoothDataType -json`, read off the main thread).
// Checks which Bluetooth devices are connected every 3 s and re-reads levels
// right away when that changes (AirPods out of or into the case), else every
// 60 s. A change is "news" for 10 s, which lifts the widget's priority.
// Plugging in or unplugging the Mac re-reads at once (power source
// notification, also posted as `.powerChanged` for the Mac widget).
import IOBluetooth
import IOKit.ps
import SwiftUI

struct BatteryItem: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let percent: Int
    var charging = false
    /// On power but not charging (held by macOS): shows a plug instead of a bolt.
    var plugged = false
    /// Bluetooth product ID (Apple's AirPods models: 0x2002 and up).
    var productID: Int?
}

@MainActor
final class Batteries: ObservableObject {
    @Published private(set) var items: [BatteryItem] = []
    /// Last time a device connected or disconnected.
    @Published private(set) var news: Date?

    private var connected = Set<String>()

    init() {
        if Config.demo != nil {
            items = [BatteryItem(id: "mac", name: "MacBook", symbol: "laptopcomputer", percent: 84),
                     BatteryItem(id: "pods", name: "AirPods Pro", symbol: "airpods", percent: 62)]
            return
        }
        connected = Self.connectedDevices()
        refresh()
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            NotificationCenter.default.post(name: .powerChanged, object: nil)
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        NotificationCenter.default.addObserver(forName: .powerChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchConnections() }
        }
    }

    var isNews: Bool { news.map { -$0.timeIntervalSinceNow < 10 } ?? false }

    private func watchConnections() {
        let now = Self.connectedDevices()
        guard now != connected else { return }
        // Headphones or speakers just connected: the music widget comes back.
        let arrived = now.subtracting(connected)
        if (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).contains(where: {
            arrived.contains($0.addressString ?? "") && $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
        }) {
            NotificationCenter.default.post(name: .audioConnected, object: nil)
        }
        connected = now
        news = Date()
        // Levels reach system_profiler a moment after connecting.
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.5) { self.objectWillChange.send() }
    }

    private static func connectedDevices() -> Set<String> {
        Set((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }.compactMap(\.addressString))
    }

    private func refresh() {
        let mac = Self.macBattery()
        Task.detached(priority: .utility) {
            let devices = Self.bluetoothBatteries()
            await MainActor.run {
                let items = (mac.map { [$0] } ?? []) + devices
                if items != self.items { self.items = items }
            }
        }
    }

    private static func macBattery() -> BatteryItem? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return BatteryItem(id: "mac", name: "MacBook", symbol: "laptopcomputer", percent: current * 100 / max,
                               charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                               plugged: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }

    nonisolated private static func bluetoothBatteries() -> [BatteryItem] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }
        var items: [BatteryItem] = []
        for controller in controllers {
            for group in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in group {
                    guard let d = value as? [String: Any] else { continue }
                    // AirPods report left/right/case; others a single level.
                    let levels = ["device_batteryLevelMain", "device_batteryLevelLeft", "device_batteryLevelRight"]
                        .compactMap { (d[$0] as? String).flatMap { Int($0.filter(\.isNumber)) } }
                    guard let lowest = levels.min() else { continue }
                    let minor = (d["device_minorType"] as? String ?? "").lowercased()
                    let symbol = minor.contains("headphones") || name.lowercased().contains("airpods") ? "airpods"
                        : minor.contains("mouse") ? "computermouse"
                        : minor.contains("keyboard") ? "keyboard"
                        : minor.contains("trackpad") ? "rectangle.and.hand.point.up.left" : "dot.radiowaves.left.and.right"
                    let pid = (d["device_productID"] as? String).flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
                    items.append(BatteryItem(id: name, name: name, symbol: symbol, percent: lowest, productID: pid))
                }
            }
        }
        return items
    }
}

struct BatteriesView: View {
    @ObservedObject var batteries: Batteries

    var body: some View {
        Button { Drawers.shared.toggle("batteries") } label: { row }
            .buttonStyle(WidgetPress())
            .contextMenu { Button("Bluetooth Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) } }
    }

    private var row: some View {
        HStack(spacing: 14) {
            ForEach(batteries.items) { item in
                VStack(spacing: 4) {
                    Image(systemName: item.symbol).font(.system(size: 17, weight: .medium))
                        .frame(height: 20)
                    HStack(spacing: 2) {
                        if item.charging { Image(systemName: "bolt.fill").font(.system(size: 9)) }
                        else if item.plugged { Image(systemName: "powerplug.fill").font(.system(size: 9)) }
                        Text("\(item.percent)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    // Never wrap "64" and "%" onto two lines.
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(item.percent <= 20 ? AnyShapeStyle(Color(red: 1, green: 0.42, blue: 0.38)) : AnyShapeStyle(ink(0.85)))
                }
                .transition(.rise)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: batteries.items)
    }
}

/// Drawer content: every device with its name and level.
struct BatteryList: View {
    @ObservedObject var batteries: Batteries

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(batteries.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 22)
                    Text(item.name).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 20)
                    if item.charging { Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                    else if item.plugged { Image(systemName: "powerplug.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Gauge(value: Double(item.percent), in: 0...100) {}
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(item.percent <= 20 ? .red : .white)
                        .frame(width: 60)
                    Text("\(item.percent)%").font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 260)
        .card()
    }
}
