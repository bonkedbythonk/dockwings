// Puts the notch window on the lock screen while the Mac is locked, the way
// notch apps do it: a private SkyLight space at absolute level 400 (above
// the lock screen at 300), created once; on lock the window moves into it,
// on unlock (after 150 ms, against flicker) it leaves again. Private API
// with guessed signatures: if a symbol is missing nothing happens. What the
// notch shows while locked is limited in Notch (`lockSafe`).
import AppKit

@MainActor
enum LockScreen {
    private typealias Conn = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias Level = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias Show = @convention(c) (Int32, CFArray) -> Int32
    private typealias Add = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias Remove = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private static let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
    private static func fn<T>(_ name: String, _ type: T.Type) -> T? { dlsym(sl, name).map { unsafeBitCast($0, to: type) } }

    private static var connection: Int32 = 0
    private static var space: Int32 = 0

    static func attach(_ windows: [NSWindow], onChange: @escaping (Bool) -> Void) {
        guard let conn = fn("SLSMainConnectionID", Conn.self), let create = fn("SLSSpaceCreate", Create.self),
              let level = fn("SLSSpaceSetAbsoluteLevel", Level.self), let show = fn("SLSShowSpaces", Show.self),
              let add = fn("SLSSpaceAddWindowsAndRemoveFromSpaces", Add.self),
              let remove = fn("SLSRemoveWindowsFromSpaces", Remove.self) else { return }
        connection = conn()
        space = create(connection, 1, 0)
        _ = level(connection, space, 400)
        _ = show(connection, [space] as CFArray)
        for window in windows { window.canBecomeVisibleWithoutLogin = true }
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                _ = add(connection, space, windows.map(\.windowNumber) as CFArray, 7)
                onChange(true)
            }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                onChange(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    _ = remove(connection, windows.map(\.windowNumber) as CFArray, [space] as CFArray)
                }
            }
        }
    }
}
