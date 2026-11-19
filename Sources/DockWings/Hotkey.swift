// Global shortcut: Ctrl+Option+B shows or hides all the buddies (flips the
// "buddy" setting, which Buddy watches). Carbon hot keys need no permission.

import AppKit
import Carbon.HIToolbox

@MainActor
enum Hotkey {
    private static var ref: EventHotKeyRef?

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated {
                let d = UserDefaults.standard
                d.set(!d.bool(forKey: "buddy"), forKey: "buddy")
            }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4457_4E47), id: 1) // "DWNG"
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
