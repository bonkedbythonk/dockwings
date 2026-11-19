// Microphone and camera widget: shows while any app records from a microphone
// or uses a camera, with that app's icon and an orange (microphone) or green
// (camera) dot like the menu bar's privacy indicator. The microphone user
// comes from Core Audio's process objects (kAudioProcessPropertyIsRunningInput);
// a helper process (a browser's renderer) is shown as its parent app. Which
// app uses the camera isn't public, so the camera is shown alone, or with the
// app that also has the microphone. Checked every 2 s; no permission needed.
import AppKit
import CoreAudio
import CoreMediaIO
import SwiftUI

@MainActor
final class InUse: ObservableObject {
    static let shared = InUse()

    struct State: Hashable {
        var microphone = false
        var camera = false
        /// The app recording from the microphone, if known.
        var pid: pid_t?
        var name: String?
    }

    @Published private(set) var state = State()
    var active: Bool { state.microphone || state.camera }

    init() {
        if Config.demo == "a" {
            state = State(microphone: true, camera: true, pid: nil, name: "FaceTime")
            return
        }
        check()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        var next = State(camera: Self.cameraRunning())
        if let pid = Self.recordingPid() {
            next.microphone = true
            let app = Self.app(for: pid)
            next.pid = app?.processIdentifier ?? pid
            next.name = app?.localizedName
        }
        if next != state { state = next }
    }

    /// The first process (not DockWings) recording audio input. Asks the few
    /// devices first: each process read is a round trip to coreaudiod.
    private static func recordingPid() -> pid_t? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard objects(system, kAudioHardwarePropertyDevices).contains(where: { device in
            var running: UInt32 = 0
            return read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, &running) && running != 0 && hasInput(device)
        }) else { return nil }
        for object in objects(system, kAudioHardwarePropertyProcessObjectList) {
            var input: UInt32 = 0
            var pid: pid_t = 0
            guard read(object, kAudioProcessPropertyIsRunningInput, &input), input != 0,
                  read(object, kAudioProcessPropertyPID, &pid), pid != getpid()
            else { continue }
            return pid
        }
        return nil
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func objects(_ owner: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = Self.address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(owner, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(owner, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    /// The app a process belongs to: itself when it's a regular app, else its
    /// parent's app (helper processes), else nothing.
    private static func app(for pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<3 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            var info = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  info.pbi_ppid > 1
            else { break }
            current = pid_t(info.pbi_ppid)
        }
        return nil
    }

    private static func cameraRunning() -> Bool {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }
        var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        return devices.contains { device in
            var on: UInt32 = 0
            var got: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &on) == noErr && on != 0
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}

struct InUseView: View {
    @ObservedObject var inUse: InUse

    var body: some View {
        let state = inUse.state
        if inUse.active {
            HStack(spacing: 10) {
                if let pid = state.pid, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 34, height: 34)
                } else {
                    Image(systemName: state.camera ? "video.fill" : "mic.fill").font(.system(size: 20, weight: .medium)).frame(width: 34)
                }
                Lines(title: state.name ?? (state.camera ? "Camera" : "Microphone"),
                      subtitle: state.camera && state.microphone ? "Camera and microphone" : state.camera ? "Camera on" : "Microphone on",
                      maxWidth: 150)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    if state.camera { Circle().fill(Color(red: 0.2, green: 0.8, blue: 0.4)).frame(width: 7, height: 7) }
                    if state.microphone { Circle().fill(Color(red: 1, green: 0.62, blue: 0.2)).frame(width: 7, height: 7) }
                }
                .offset(x: -3, y: 2)
            }
            .tapAction {
                if let pid = state.pid { NSRunningApplication(processIdentifier: pid)?.activate() }
            }
            .transition(.blurReplace)
        }
    }
}
