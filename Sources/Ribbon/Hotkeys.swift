import AppKit
import RibbonCore

/// Global key bindings and scroll-wheel panning through a CGEventTap at the
/// HID level (as Paneru does). Sitting that early lets bound keys be
/// swallowed before macOS acts on them, e.g. Ctrl+arrow switching Spaces.
final class Hotkeys {
    var bindings: [KeyCombo: Command] = [:]
    var panModifiers: KeyCombo.Modifiers?
    var isPaused: () -> Bool = { false }
    var onCommand: (Command) -> Void = { _ in }
    var onPan: (Double) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func configure(_ settings: Settings) {
        var parsed: [KeyCombo: Command] = [:]
        for (combo, name) in settings.effectiveBindings {
            guard let key = KeyCombo(combo), let command = Command(rawValue: name) else {
                log("ignoring binding \(combo) = \(name)")
                continue
            }
            parsed[key] = command
        }
        bindings = parsed
        let pan = settings.panModifiers.isEmpty ? nil : KeyCombo("\(settings.panModifiers)+left")?.modifiers
        panModifiers = pan.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Fails without Accessibility permission.
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                Unmanaged<Hotkeys>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let command = bindings[KeyCombo(keyCode: code, modifiers: Self.modifiers(event.flags))] else { break }
            if isPaused() && command != .togglePause { break }
            // Return at once; the work happens on the next run-loop turn so a
            // slow app can't stall the tap and get it disabled.
            DispatchQueue.main.async { self.onCommand(command) }
            return nil
        case .scrollWheel:
            guard let panModifiers, !isPaused(), Self.modifiers(event.flags) == panModifiers else { break }
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let delta = abs(dx) > abs(dy) ? -dx : -dy
            DispatchQueue.main.async { self.onPan(delta) }
            return nil
        default:
            break
        }
        return pass
    }

    static func modifiers(_ flags: CGEventFlags) -> KeyCombo.Modifiers {
        var m: KeyCombo.Modifiers = []
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        return m
    }
}
