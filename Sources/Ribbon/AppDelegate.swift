import AppKit
import ApplicationServices
import RibbonCore
import ServiceManagement

struct Options {
    /// Only manage these apps (name or bundle ID). Empty means all.
    var only: [String] = []
    var configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ribbon/config.json")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: Options
    private var settings = Settings()
    private var controller: Controller?
    private let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionTimer: Timer?

    init(options: Options) {
        self.options = options
    }

    private var isEnabled: Bool { !(controller?.paused ?? !UserDefaults.standard.enabled) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            log("Ribbon is already running")
            NSApp.terminate(nil)
            return
        }
        setUpStatusItem()
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            begin()
        } else {
            log("waiting for Accessibility permission (System Settings › Privacy & Security › Accessibility)")
            refreshStatus()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.permissionTimer = nil
                self?.begin()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        controller?.restoreAll()
        log("bye: every window is back on screen")
    }

    private func begin() {
        settings = loadSettings()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        let only = options.only
        let excluded = settings.excludeApps
        let stateName = only.isEmpty ? "state.json" : "state-only.json"
        let stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ribbon/\(stateName)")
        let controller = Controller(settings: settings, stateURL: stateURL, enabled: UserDefaults.standard.enabled) { app in
            let names = [app.localizedName, app.bundleIdentifier].compactMap { $0 }
            if names.contains(where: excluded.contains) { return false }
            return only.isEmpty || names.contains(where: only.contains)
        }
        controller.onUpdate = { [weak self] in self?.refreshStatus() }
        self.controller = controller
        controller.start()

        hotkeys.configure(settings)
        hotkeys.isPaused = { [weak controller] in controller?.paused ?? false }
        hotkeys.onCommand = { [weak controller] in controller?.run($0) }
        hotkeys.onPan = { [weak controller] in controller?.pan($0) }
        if !hotkeys.start() {
            log("could not install the keyboard event tap; check Accessibility permission")
        }
        warnAboutSpaceShortcuts()

        DistributedNotificationCenter.default().addObserver(
            forName: commandNotification, object: nil, queue: .main
        ) { [weak controller] note in
            guard let name = note.object as? String else { return }
            guard let command = Command(rawValue: name) else {
                log("unknown command \(name)")
                return
            }
            controller?.run(command)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak controller] _ in controller?.layout(animated: false) }

        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        refreshStatus()
        log("ready. \(hotkeys.bindings.count) key bindings; config: \(options.configURL.path)")
    }

    private func loadSettings() -> Settings {
        do {
            return try Settings.load(from: options.configURL)
        } catch {
            log("config error, using defaults: \(error)")
            return Settings()
        }
    }

    /// Ctrl+arrows are macOS's "Move left/right a space" shortcuts. The HID
    /// event tap normally wins, but say so in case they still fire.
    private func warnAboutSpaceShortcuts() {
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") else { return }
        let enabled = ["79", "80", "81", "82"].contains { key in
            ((hotkeys[key] as? [String: Any])?["enabled"] as? Bool) ?? false
        }
        if enabled {
            log("note: Mission Control's Ctrl+←/→ Space shortcuts are on. While Ribbon is on it intercepts them; "
                + "if Spaces still switch, turn them off in System Settings › Keyboard › Keyboard Shortcuts › Mission Control.")
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Ribbon")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshStatus()
    }

    /// Rebuilt each time it opens, so checkmarks and counts are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard controller != nil else {
            menu.addItem(item("Ribbon needs Accessibility access", nil))
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
            menu.addItem(item("Quit Ribbon", #selector(quit), key: "q"))
            return
        }
        let toggle = item("Ribbon On", #selector(toggleEnabled), key: "p", modifiers: [.control, .option])
        toggle.state = isEnabled ? .on : .off
        menu.addItem(toggle)
        if let controller, isEnabled {
            let strip = controller.strip
            let position = strip.focusedIndex.map { "window \($0 + 1) of \(strip.count)" } ?? "\(strip.count) windows"
            menu.addItem(item("This Space: \(position)", nil))
        }
        menu.addItem(.separator())
        let smooth = item("Smooth Motion", #selector(toggleSmoothMotion))
        smooth.state = controller?.smoothMotion == true ? .on : .off
        menu.addItem(smooth)
        menu.addItem(item("Retile Windows", #selector(retile)))
        menu.addItem(shortcutsMenu())
        menu.addItem(.separator())
        if Bundle.main.bundleIdentifier != nil {
            let login = item("Start at Login", #selector(toggleLoginItem))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(item("Open Config…", #selector(openConfig)))
        menu.addItem(item("Reload Config", #selector(reloadConfig)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Ribbon", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector?, key: String = "",
                      modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.isEnabled = action != nil
        return item
    }

    private func shortcutsMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Keyboard Shortcuts", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let order = Command.allCases
        let rows = hotkeys.bindings
            .sorted { (order.firstIndex(of: $0.value) ?? 0, $0.key.description) < (order.firstIndex(of: $1.value) ?? 0, $1.key.description) }
        for (combo, command) in rows {
            let row = NSMenuItem(title: "\(Self.symbols(combo))\t\(command.label)", action: nil, keyEquivalent: "")
            row.isEnabled = false
            submenu.addItem(row)
        }
        parent.submenu = submenu
        return parent
    }

    private static func symbols(_ combo: KeyCombo) -> String {
        var s = ""
        if combo.modifiers.contains(.control) { s += "⌃" }
        if combo.modifiers.contains(.option) { s += "⌥" }
        if combo.modifiers.contains(.shift) { s += "⇧" }
        if combo.modifiers.contains(.command) { s += "⌘" }
        let key = combo.description.split(separator: "+").last.map(String.init) ?? ""
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "minus": "-", "equal": "=",
                     "return": "↩", "space": "Space", "tab": "⇥", "escape": "⎋",
                     "leftbracket": "[", "rightbracket": "]", "backslash": "\\"]
        return s + (names[key] ?? key.uppercased())
    }

    private func refreshStatus() {
        guard let button = statusItem?.button else { return }
        if controller == nil {
            button.title = " needs access"
            button.appearsDisabled = true
            return
        }
        button.appearsDisabled = !isEnabled
        if isEnabled, let strip = controller?.strip, let focused = strip.focusedIndex {
            button.title = " \(focused + 1)/\(strip.count)"
        } else {
            button.title = ""
        }
    }

    @objc private func toggleEnabled() { controller?.run(.togglePause) }
    @objc private func retile() { controller?.run(.retile) }
    @objc private func toggleSmoothMotion() { controller?.smoothMotion.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Start at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add Ribbon by hand in System Settings › General › Login Items."
            alert.runModal()
        }
    }

    @objc private func openConfig() {
        let url = options.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(sampleConfig.utf8).write(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func reloadConfig() {
        settings = loadSettings()
        hotkeys.configure(settings)
        controller?.apply(settings)
        log("config reloaded")
    }
}

extension UserDefaults {
    /// Whether tiling is on. Survives restarts; defaults to on.
    var enabled: Bool { object(forKey: "enabled") as? Bool ?? true }
}

private extension Command {
    var label: String {
        switch self {
        case .focusLeft: "Focus window to the left"
        case .focusRight: "Focus window to the right"
        case .pageLeft: "Previous set of windows"
        case .pageRight: "Next set of windows"
        case .moveLeft: "Move window left"
        case .moveRight: "Move window right"
        case .grow: "Wider (next preset)"
        case .shrink: "Narrower (previous preset)"
        case .cycleWidth: "Cycle width presets"
        case .widen: "Wider by a step"
        case .narrow: "Narrower by a step"
        case .toggleFill: "Fill screen / restore width"
        case .center: "Center window"
        case .toggleFloat: "Float / tile window"
        case .tabIntoLeft: "Tab into the window on the left"
        case .tabIntoRight: "Tab into the window on the right"
        case .untab: "Move tab out of its group"
        case .prevTab: "Previous tab"
        case .nextTab: "Next tab"
        case .retile: "Retile"
        case .togglePause: "Turn Ribbon on / off"
        case .dump: "Log layout"
        case .quit: "Quit"
        }
    }
}

private let sampleConfig = """
{
  "gap": 8,
  "widthPresets": [0.3333, 0.5, 0.6667, 1.0],
  "defaultWidth": null,
  "widthStep": 0.05,
  "sliver": 5,
  "animationDuration": 0.12,
  "panModifiers": "ctrl+alt",
  "panSpeed": 1.0,
  "excludeApps": [],
  "bindings": {
    "ctrl+left": "focus-left",
    "ctrl+right": "focus-right",
    "ctrl+shift+left": "page-left",
    "ctrl+shift+right": "page-right"
  }
}

"""
