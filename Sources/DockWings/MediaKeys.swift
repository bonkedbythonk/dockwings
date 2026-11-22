// Volume and brightness keys, shown in the notch instead of the system HUD.
// An event tap (Accessibility permission) catches the media keys before
// macOS does and swallows them; DockWings then sets the level itself
// (CoreAudio for volume, the private DisplayServices framework for the
// built-in display's brightness) and posts a notch alert. Keys it can't
// handle pass through untouched: Option alone (opens the settings pane), an
// output device without volume control, an external main display, the
// keyboard backlight. Steps of 1/16, or 1/64 with Option-Shift, like macOS;
// each step glides there (`Glide`) instead of jumping, for sound and light.
import AppKit
import AudioToolbox
import CoreAudio

@MainActor
enum MediaKeys {
    private static var tap: CFMachPort?

    static func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << 14)  // NX_SYSDEFINED
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let tap = MediaKeys.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            let handled = MainActor.assumeIsolated { MediaKeys.handle(event) }
            return handled ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        Volume.watchOutside()
    }

    /// True when the key was used (the event is then swallowed, down and up).
    private static func handle(_ event: CGEvent) -> Bool {
        guard Notch.hudOn, let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return false }
        let key = (ns.data1 & 0xFFFF0000) >> 16
        let down = (ns.data1 & 0xFF00) >> 8 == 0xA
        let flags = ns.modifierFlags.intersection([.option, .shift])
        if flags == .option { return false }
        let step: Float = flags == [.option, .shift] ? 1 / 64 : 1 / 16
        switch key {
        case 0, 1, 7:
            guard let device = Volume.device, Volume.settable(device) else { return false }
            if down { Volume.press(key, step: step, device: device) }
            return true
        case 2, 3:
            guard CGDisplayIsBuiltin(CGMainDisplayID()) != 0, Brightness.available else { return false }
            if down { Brightness.press(up: key == 2, step: step) }
            return true
        default:
            return false
        }
    }

    static func nudgeVolume(_ delta: Float) { Volume.nudge(delta) }

    static func show(volume: Float, muted: Bool) {
        guard Notch.hudOn else { return }
        let level = muted || volume == 0 ? "speaker.slash.fill" : volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        // Like Alcove: the icon is the output itself when it's headphones.
        let symbol = Volume.headphoneSymbol.map { muted ? "speaker.slash.fill" : $0 } ?? level
        Notch.shared.post(NotchAlert(id: "hud", icon: .symbol(symbol, .white, .swap), trailing: .level(muted ? -Double(max(volume, 0.001)) : Double(volume)),
                                     title: "Volume", subtitle: muted ? "Muted" : "\(Int((volume * 100).rounded()))%",
                                     duration: 1.5, jumpsQueue: true, label: "Sound"))
    }
}

private enum Volume {
    static var device: AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// AirPods or other Bluetooth headphones as the output: their symbol.
    static var headphoneSymbol: String? {
        guard let device else { return nil }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var t = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &t, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var n = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        let title = AudioObjectGetPropertyData(device, &n, 0, nil, &size, &name) == noErr ? (name?.takeRetainedValue() as String? ?? "") : ""
        if let pid = Notch.productIDs[title], let symbol = Notch.airpodsSymbol(pid) { return symbol }
        if title.contains("AirPods Max") { return "airpodsmax" }
        if title.contains("AirPods Pro") { return "airpodspro" }
        if title.contains("AirPods") { return "airpods" }
        return "headphones"
    }

    static func settable(_ device: AudioObjectID) -> Bool {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &a) && AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
    }

    static func get(_ device: AudioObjectID) -> (volume: Float, muted: Bool) {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &volume)
        var m = address(kAudioDevicePropertyMute)
        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectHasProperty(device, &m) && AudioObjectGetPropertyData(device, &m, 0, nil, &size, &mute) == noErr
        return (volume, hasMute && mute != 0)
    }

    static func setMute(_ device: AudioObjectID, _ on: Bool) {
        var m = address(kAudioDevicePropertyMute)
        var value: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(device, &m, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func set(_ device: AudioObjectID, _ volume: Float) {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(volume)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    @MainActor private static let glide = Glide(read: { device.map { get($0).volume } ?? 0 },
                                                write: { v in if let d = device { set(d, v) } })

    /// Volume changed anywhere else (the menu bar, other apps): the HUD shows
    /// it too, except for AirPods swipes (`isSwipe`). Follows the output device when it changes.
    @MainActor
    static func watchOutside() {
        var system = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &system, .main) { _, _ in
            MainActor.assumeIsolated { listen() }
        }
        listen()
    }

    @MainActor private static var listening: AudioObjectID?
    /// CoreAudio also notifies when nothing changed (device wakes, playback starts),
    /// and AirPods ramp the volume by themselves in 1-2% steps (Conversation Awareness,
    /// Personalized Volume): neither shows. Sliders jump further.
    @MainActor private static var last: (volume: Float, muted: Bool)?
    @MainActor private static let changed: AudioObjectPropertyListenerBlock = { _, _ in
        MainActor.assumeIsolated {
            guard let device = listening else { return }
            let now = get(device)
            defer { last = now }
            guard glide.target == nil, let last,  // own key presses show themselves
                  abs(now.volume - last.volume) > 0.035 || now.muted != last.muted else { return }
            if now.muted == last.muted, isSwipe(from: last.volume, to: now.volume) { return }
            MediaKeys.show(volume: now.volume, muted: now.muted)
        }
    }

    /// A swipe on AirPods: macOS shows its own banner, which can't be hidden, so the
    /// notch stays quiet. Bluetooth volume comes in 1/127 steps, a swipe moves 8 of them.
    private static func isSwipe(from old: Float, to new: Float) -> Bool {
        let steps = new * 127
        return abs(steps - steps.rounded()) < 0.001 && abs(new - old) < 8.5 / 127 && headphoneSymbol != nil
    }

    @MainActor
    private static func listen() {
        if let old = listening {
            for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
                var a = address(sel)
                AudioObjectRemovePropertyListenerBlock(old, &a, .main, changed)
            }
        }
        listening = device
        guard let device else { last = nil; return }
        last = get(device)
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var a = address(sel)
            AudioObjectAddPropertyListenerBlock(device, &a, .main, changed)
        }
    }

    /// A trackpad scroll over the open notch: free amounts, no grid.
    @MainActor
    static func nudge(_ delta: Float) {
        guard let device, settable(device) else { return }
        let volume = glide.nudge(by: delta)
        if get(device).muted { setMute(device, false) }
        MediaKeys.show(volume: volume, muted: false)
    }

    @MainActor
    static func press(_ key: Int, step: Float, device: AudioObjectID) {
        var (volume, muted) = get(device)
        if key == 7 {
            muted.toggle()
            setMute(device, muted)
            volume = glide.target ?? volume
        } else {
            volume = glide.step(by: key == 0 ? step : -step)
            if muted { setMute(device, false); muted = false }
            feedback()
        }
        MediaKeys.show(volume: volume, muted: muted)
    }

    /// The click macOS plays on volume changes, when that setting is on.
    private static func feedback() {
        guard UserDefaults(suiteName: ".GlobalPreferences")?.integer(forKey: "com.apple.sound.beep.feedback") == 1 else { return }
        NSSound(contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff", byReference: true)?.play()
    }
}

private enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let setter = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }

    static var available: Bool { getter != nil && setter != nil }

    @MainActor private static let glide = Glide(read: {
        var level: Float = 0
        _ = getter?(CGMainDisplayID(), &level)
        return level
    }, write: { _ = setter?(CGMainDisplayID(), $0) })

    @MainActor
    static func press(up: Bool, step: Float) {
        let level = glide.step(by: up ? step : -step)
        let symbol = level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        Notch.shared.post(NotchAlert(id: "hud", icon: .symbol(symbol, .white, .swap), trailing: .level(Double(level)),
                                     title: "Brightness", subtitle: "\(Int((level * 100).rounded()))%",
                                     duration: 1.5, jumpsQueue: true, label: "Display"))
    }
}

/// Moves a level to its target over about 150 ms at 60 steps a second
/// (ease-out), so a key press slides instead of jumping. Presses during a
/// glide step from the target, so fast presses don't lose steps.
@MainActor
final class Glide {
    private let read: () -> Float
    private let write: (Float) -> Void
    private var value: Float = 0
    private(set) var target: Float?
    private var timer: Timer?

    init(read: @escaping () -> Float, write: @escaping (Float) -> Void) {
        self.read = read
        self.write = write
    }

    /// Snaps to the step grid like macOS, then glides there; returns the target.
    func step(by step: Float) -> Float {
        if timer == nil { value = read() }
        let base = target ?? value
        let next = min(1, max(0, ((base / abs(step)).rounded() + (step > 0 ? 1 : -1)) * abs(step)))
        target = next
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        return next
    }

    /// Moves the target by a free amount (scrolling), then glides there.
    func nudge(by delta: Float) -> Float {
        if timer == nil { value = read() }
        let next = min(1, max(0, (target ?? value) + delta))
        target = next
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        return next
    }

    private func tick() {
        guard let target else { return }
        value += (target - value) * 0.3
        if abs(target - value) < 0.002 {
            value = target
            self.target = nil
            timer?.invalidate()
            timer = nil
        }
        write(value)
    }
}
