import AppKit
import ApplicationServices
import RibbonCore

// Private but long-stable: maps an AX window element to its CGWindowID
// (used by Paneru, yabai and AeroSpace alike).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (copy(element, attribute) as? NSNumber)?.boolValue
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (copy(element, attribute) as? [AXUIElement]) ?? []
    }

    static func point(_ element: AXUIElement) -> CGPoint? {
        guard let value = copy(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = copy(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func windowID(_ element: AXUIElement) -> WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Apps like Chrome animate frame changes while AXEnhancedUserInterface is on.
    private static var enhancedUIDisabled = Set<pid_t>()
    /// Apps seen with it off; skips an AX round trip on every move.
    private static var enhancedUIAbsent = Set<pid_t>()

    static func suspendEnhancedUI(_ pid: pid_t) {
        guard !enhancedUIDisabled.contains(pid), !enhancedUIAbsent.contains(pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        if bool(app, "AXEnhancedUserInterface") == true {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            enhancedUIDisabled.insert(pid)
        } else {
            enhancedUIAbsent.insert(pid)
        }
    }

    static func resumeEnhancedUI() {
        for pid in enhancedUIDisabled {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        enhancedUIDisabled.removeAll()
    }
}

/// Private SkyLight calls for focusing a specific window, looked up at runtime.
private enum SkyLight {
    struct PSN { var high: UInt32 = 0; var low: UInt32 = 0 }
    typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    typealias PostEvent = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let setFront: SetFront? = symbol(handle, "_SLPSSetFrontProcessWithOptions")
    static let postEvent: PostEvent? = symbol(handle, "SLPSPostEventRecordTo")
    static let getPSN: GetPSN? = symbol(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID")

    static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

final class AXWindow {
    let element: AXUIElement
    let id: WindowID
    let pid: pid_t

    init?(element: AXUIElement, pid: pid_t) {
        guard let id = AX.windowID(element) else { return nil }
        self.element = element
        self.id = id
        self.pid = pid
    }

    var frame: CGRect? {
        guard let origin = AX.point(element), let size = AX.size(element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var title: String { AX.string(element, kAXTitleAttribute) ?? "" }
    var role: String? { AX.string(element, kAXRoleAttribute) }
    var subrole: String? { AX.string(element, kAXSubroleAttribute) }
    var isMinimized: Bool { AX.bool(element, kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { AX.bool(element, "AXFullScreen") ?? false }

    /// A normal document/app window we should tile: not a dialog, sheet,
    /// panel, popover, or something minimised or in native full screen.
    var isTileable: Bool {
        guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole,
              !isMinimized, !isFullScreen, let frame, frame.width > 60, frame.height > 60
        else { return false }
        return true
    }

    func setPosition(_ point: CGPoint) {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    func setSize(_ size: CGSize) {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    func close() {
        guard let button = AX.element(element, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    /// Brings this exact window to the front and makes it key.
    func focus() {
        var psn = SkyLight.PSN()
        if let getPSN = SkyLight.getPSN, let setFront = SkyLight.setFront, getPSN(pid, &psn) == 0 {
            _ = setFront(&psn, id, 0x200) // kCPSUserGenerated
            makeKey(&psn)
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Synthesised window-server event that makes the window key (from Paneru).
    /// Skipped on macOS 14, where this record crashes the target app.
    private func makeKey(_ psn: inout SkyLight.PSN) {
        guard let post = SkyLight.postEvent,
              ProcessInfo.processInfo.operatingSystemVersion.majorVersion != 14 else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: id) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = post(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = post(&psn, &bytes)
    }
}
