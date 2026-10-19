import AppKit
import RibbonCore

typealias SpaceID = UInt64

/// Which macOS Space is showing, and which Space a window lives on. AX can't
/// tell; these SkyLight calls can (Paneru and yabai use the same ones).
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection: Int32 = symbol("SLSMainConnectionID", as: MainConnection.self)?() ?? 0
    private static let activeSpace = symbol("SLSGetActiveSpace", as: ActiveSpace.self)
    private static let spacesForWindows = symbol("SLSCopySpacesForWindows", as: SpacesForWindows.self)

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// The Space on screen now; 0 if SkyLight is unavailable, which
    /// collapses everything into a single strip.
    static var active: SpaceID {
        activeSpace?(connection) ?? 0
    }

    static func space(of window: WindowID) -> SpaceID? {
        guard let spacesForWindows,
              let spaces = spacesForWindows(connection, 0x7, [NSNumber(value: window)] as CFArray)?
                .takeRetainedValue() as? [NSNumber] else { return nil }
        return spaces.first?.uint64Value
    }
}
