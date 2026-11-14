import AppKit

/// Puts a window where the lock screen can see it.
///
/// macOS hides every app's windows while the Mac is locked. The window server
/// (SkyLight) has its own layers above that, which the system uses for things
/// like notifications on the lock screen. These calls are private and
/// undocumented, so a macOS update can change them: every lookup is checked
/// and the app carries on without the lock screen player if one is missing.
enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int, Int) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void

    /// The layer the system uses for notifications over the lock screen.
    static let lockScreenLevel: Int32 = 400

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
    private static var space: UInt64?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// Moves `window` onto the lock screen layer. The window has to be on
    /// screen already. Returns false if this macOS no longer supports it.
    @discardableResult
    static func moveToLockScreen(_ window: NSWindow) -> Bool {
        guard
            let mainConnection = symbol("SLSMainConnectionID", as: MainConnectionID.self),
            let createSpace = symbol("SLSSpaceCreate", as: SpaceCreate.self),
            let setLevel = symbol("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
            let showSpaces = symbol("SLSShowSpaces", as: ShowSpaces.self),
            let addWindows = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindowsAndRemoveFromSpaces.self)
        else { return false }

        let connection = mainConnection()
        if space == nil {
            let created = createSpace(connection, 1, 0)
            guard created != 0 else { return false }
            setLevel(connection, created, lockScreenLevel)
            showSpaces(connection, [created] as CFArray)
            space = created
        }
        guard let space else { return false }
        addWindows(connection, space, [window.windowNumber] as CFArray, 7)
        return true
    }
}
