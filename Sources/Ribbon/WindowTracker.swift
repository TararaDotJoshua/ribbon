import AppKit
import ApplicationServices
import RibbonCore

protocol WindowTrackerDelegate: AnyObject {
    func windowAppeared(_ window: AXWindow)
    func windowDisappeared(_ id: WindowID)
    func windowFocused(_ id: WindowID)
    /// Moved or resized by something other than us (or by us; the delegate checks).
    func windowFrameChanged(_ id: WindowID)
}

/// Finds tileable windows and reports their lifecycle, via NSWorkspace for
/// apps and one AXObserver per app for windows.
final class WindowTracker {
    weak var delegate: WindowTrackerDelegate?
    private(set) var windows: [WindowID: AXWindow] = [:]
    private var apps: [pid_t: AppObserver] = [:]
    private let shouldManage: (NSRunningApplication) -> Bool

    init(shouldManage: @escaping (NSRunningApplication) -> Bool) {
        self.shouldManage = shouldManage
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.track(app)
            // Many apps open their first window a moment after launching.
            for delay in [0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.scan(app.processIdentifier) }
            }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.untrack(app.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.untrack(app.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.track(app)
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.reportFocus(app.processIdentifier)
        }

        for app in NSWorkspace.shared.runningApplications {
            track(app)
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for pid in Array(apps.keys) { untrack(pid, notify: false) }
    }

    /// The window that currently has keyboard focus, if we know it.
    func focusedWindowID() -> WindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return focusedWindowID(pid)
    }

    func rescanAll() {
        for app in NSWorkspace.shared.runningApplications { track(app) }
        for pid in Array(apps.keys) { scan(pid) }
    }

    // MARK: Apps

    private func track(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard apps[pid] == nil, pid != getpid(), app.activationPolicy == .regular, !app.isHidden,
              shouldManage(app) else { return }
        guard let observer = AppObserver(pid: pid, tracker: self) else { return }
        apps[pid] = observer
        scan(pid)
    }

    private func untrack(_ pid: pid_t, notify: Bool = true) {
        guard let observer = apps.removeValue(forKey: pid) else { return }
        observer.invalidate()
        for (id, window) in windows where window.pid == pid {
            windows.removeValue(forKey: id)
            if notify { delegate?.windowDisappeared(id) }
        }
    }

    /// Picks up any tileable windows of `pid` we are not tracking yet.
    func scan(_ pid: pid_t) {
        guard let observer = apps[pid] else { return }
        for element in AX.elements(observer.app, kAXWindowsAttribute) {
            guard let window = AXWindow(element: element, pid: pid), windows[window.id] == nil,
                  window.isTileable else { continue }
            windows[window.id] = window
            observer.watch(window)
            delegate?.windowAppeared(window)
        }
    }

    private func focusedWindowID(_ pid: pid_t) -> WindowID? {
        guard let observer = apps[pid],
              let element = AX.element(observer.app, kAXFocusedWindowAttribute) else { return nil }
        return AX.windowID(element)
    }

    private func reportFocus(_ pid: pid_t) {
        guard let id = focusedWindowID(pid) else { return }
        if windows[id] == nil { scan(pid) }
        if windows[id] != nil { delegate?.windowFocused(id) }
    }

    // MARK: AX notifications

    fileprivate func handle(_ notification: String, element: AXUIElement, pid: pid_t) {
        switch notification {
        case kAXWindowCreatedNotification:
            scan(pid)
            // Some apps set the subrole a beat after creating the window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.scan(pid) }
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { reportFocus(pid) }
        case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            guard let window = windows.values.first(where: { $0.pid == pid && CFEqual($0.element, element) }) else { return }
            // Keep watching: a minimised window reports when it comes back.
            windows.removeValue(forKey: window.id)
            delegate?.windowDisappeared(window.id)
        case kAXWindowDeminiaturizedNotification:
            // Minimised windows report as AXDialog until they settle back.
            scan(pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.scan(pid) }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let id = AX.windowID(element), windows[id] != nil { delegate?.windowFrameChanged(id) }
        default:
            break
        }
    }
}

/// One AXObserver per app, delivering on the main run loop.
private final class AppObserver {
    let pid: pid_t
    let app: AXUIElement
    private let observer: AXObserver
    private unowned let tracker: WindowTracker

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification,
    ]

    init?(pid: pid_t, tracker: WindowTracker) {
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let created else { return nil }
        self.pid = pid
        self.app = AXUIElementCreateApplication(pid)
        self.observer = created
        self.tracker = tracker
        AXUIElementSetMessagingTimeout(app, 0.5)
        for name in Self.appNotifications {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func watch(_ window: AXWindow) {
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, window.element, name as CFString, refcon)
        }
    }

    func invalidate() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    fileprivate func deliver(_ notification: String, _ element: AXUIElement) {
        tracker.handle(notification, element: element, pid: pid)
    }
}

private func axCallback(_: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue().deliver(notification as String, element)
}
