import AppKit
import QuartzCore
import RibbonCore

/// Owns the strips and keeps real windows in line with them: turns commands
/// and window events into strip changes, then moves and resizes windows to
/// match. Each macOS Space has its own strip; only the one on screen is laid out.
final class Controller: WindowTrackerDelegate {
    private(set) var settings: Settings
    private(set) var paused: Bool
    let tracker: WindowTracker
    var onUpdate: () -> Void = {}

    private var strips: [SpaceID: Strip] = [:]
    private var space: SpaceID = Spaces.active
    /// The Space each tiled window belongs to.
    private var spaceOf: [WindowID: SpaceID] = [:]
    private var floating = Set<WindowID>()
    /// The frame we last gave (or read back from) each window.
    private var applied: [WindowID: CGRect] = [:]
    private var discovered: [AXWindow]?
    /// After we focus a window, ignore stale focus reports for others for a
    /// moment, so fast repeated Ctrl+arrows don't bounce back.
    private var pendingFocus: (id: WindowID, until: Date)?
    private var changed = Set<WindowID>()
    private var changeCheck: DispatchWorkItem?
    private var animationTimer: Timer?
    private var panScheduled = false
    private var saveScheduled = false
    private let stateURL: URL

    struct SavedState: Codable {
        var spaces: [String: Strip]
        var floating: [WindowID]
    }

    /// One window going from where it is to where the strip wants it.
    private struct Change {
        let window: AXWindow
        let from: CGRect
        let to: CGRect
        /// The same two frames on the canvas, before parking at the screen edge.
        let fromCanvas: CGRect
        let toCanvas: CGRect
        var id: WindowID { window.id }
    }
    /// Each window's last canvas frame, so a glide starts from where the
    /// window really is in the strip even while it is parked.
    private var canvas: [WindowID: CGRect] = [:]

    private let tabBars = TabBars()
    private var titles: [WindowID: String] = [:]
    private let dropHighlight = DropHighlight()
    /// A window being dragged by its title bar, and the window it hovers over.
    private var drag: (window: WindowID, target: WindowID?, since: Date)?
    private var dragTimer: Timer?
    private var animationGoal: [WindowID: CGRect]?
    private var enhancedUIRestore: DispatchWorkItem?

    /// Glide windows into place instead of snapping. Either way windows never
    /// overlap mid-move.
    var smoothMotion = UserDefaults.standard.bool(forKey: "smoothMotion") {
        didSet { UserDefaults.standard.set(smoothMotion, forKey: "smoothMotion") }
    }

    init(settings: Settings, stateURL: URL, enabled: Bool, shouldManage: @escaping (NSRunningApplication) -> Bool) {
        self.settings = settings
        self.stateURL = stateURL
        paused = !enabled
        tracker = WindowTracker(shouldManage: shouldManage)
        tracker.delegate = self
        tabBars.onSelect = { [weak self] id in self?.showTab(id) }
        tabBars.onPopOut = { [weak self] id in self?.popOut(id) }
        tabBars.onClose = { [weak self] id in self?.tracker.windows[id]?.close() }
    }

    /// The strip of the Space on screen.
    private(set) var strip: Strip {
        get { strips[space] ?? newStrip() }
        set { strips[space] = newValue }
    }

    private func newStrip() -> Strip {
        var strip = Strip()
        strip.minWidth = settings.minWidth
        return strip
    }

    /// The primary display's usable area (below the menu bar, beside the
    /// Dock) in AX coordinates, whose origin is the primary's top-left.
    var geometry: Geometry {
        guard let screen = NSScreen.screens.first else {
            return Geometry(viewport: CGRect(x: 0, y: 0, width: 1440, height: 900), gap: settings.gap)
        }
        let visible = screen.visibleFrame
        let viewport = CGRect(x: visible.minX, y: screen.frame.maxY - visible.maxY,
                              width: visible.width, height: visible.height)
        return Geometry(viewport: viewport, gap: settings.gap)
    }

    func start() {
        discovered = []
        tracker.start()
        let found = discovered ?? []
        discovered = nil
        buildStrips(from: found)
        log("managing \(spaceOf.count) windows; \(strip.count) on this Space\(paused ? " (off)" : "")")
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.spaceChanged() }
        layout(animated: false)
    }

    func apply(_ newSettings: Settings) {
        settings = newSettings
        for key in strips.keys { strips[key]?.minWidth = newSettings.minWidth }
        layout(animated: true)
    }

    private func spaceChanged() {
        let active = Spaces.active
        guard active != space else { return }
        cancelAnimation()
        space = active
        // AX only lists windows on the Space on screen, so look again.
        tracker.rescanAll()
        if let focused = tracker.focusedWindowID(), strip.contains(focused) { strip.focus(focused, geometry) }
        log("space \(space): \(summary())")
        layout(animated: false)
    }

    // MARK: Commands

    func run(_ command: Command) {
        if paused, ![.togglePause, .dump, .quit].contains(command) { return }
        let g = geometry
        switch command {
        case .focusLeft: strip.focusNeighbour(.left, g)
        case .focusRight: strip.focusNeighbour(.right, g)
        case .pageLeft: strip.page(.left, g)
        case .pageRight: strip.page(.right, g)
        case .moveLeft: strip.moveFocused(.left, g)
        case .moveRight: strip.moveFocused(.right, g)
        case .grow: strip.stepPreset(.right, presets: settings.widthPresets, wrap: false, g)
        case .shrink: strip.stepPreset(.left, presets: settings.widthPresets, wrap: false, g)
        case .cycleWidth: strip.stepPreset(.right, presets: settings.widthPresets, wrap: true, g)
        case .widen: strip.nudgeWidth(by: settings.widthStep, g)
        case .narrow: strip.nudgeWidth(by: -settings.widthStep, g)
        case .toggleFill: strip.toggleFill(g)
        case .center: strip.centerFocused(g)
        case .toggleFloat: toggleFloat(g)
        case .tabIntoLeft: strip.joinNeighbour(.left, g)
        case .tabIntoRight: strip.joinNeighbour(.right, g)
        case .untab: if let id = strip.focusedWindow { strip.ungroup(id, g) }
        case .prevTab: strip.cycleTab(.left)
        case .nextTab: strip.cycleTab(.right)
        case .retile: retile(g)
        case .togglePause: togglePause(); return
        case .dump: dump(); return
        case .quit: NSApp.terminate(nil); return
        }
        log("\(command.rawValue): \(summary())")
        layout(animated: true)
        if let id = strip.focusedWindow, id != tracker.focusedWindowID() {
            pendingFocus = (id, Date().addingTimeInterval(0.6))
            tracker.windows[id]?.focus()
        }
    }

    func pan(_ delta: Double) {
        guard !paused, !strip.isEmpty else { return }
        strip.pan(by: delta * settings.panSpeed)
        guard !panScheduled else { return }
        panScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.panScheduled = false
            self?.layout(animated: false)
        }
    }

    private func toggleFloat(_ g: Geometry) {
        guard let id = tracker.focusedWindowID() ?? strip.focusedWindow, let window = tracker.windows[id] else { return }
        if floating.remove(id) != nil {
            strip.insert(id, width: initialWidth(window, g), g)
            strip.focus(id, g)
            spaceOf[id] = space
        } else if strip.contains(id) {
            floating.insert(id)
            strip.remove(id, g)
            spaceOf[id] = nil
            applied[id] = nil
            bringOnScreen(window, g)
        }
    }

    private func retile(_ g: Geometry) {
        tracker.rescanAll()
        for (id, home) in spaceOf where tracker.windows[id] == nil {
            strips[home]?.remove(id, g)
            spaceOf[id] = nil
        }
        applied.removeAll()
        strip.settle(g)
    }

    private func togglePause() {
        paused.toggle()
        UserDefaults.standard.set(!paused, forKey: "enabled")
        log(paused ? "off" : "on")
        if paused {
            cancelAnimation()
            restoreAll()
        } else {
            applied.removeAll()
            layout(animated: true)
        }
        onUpdate()
    }

    // MARK: Tab groups

    private func showTab(_ id: WindowID) {
        guard !paused, strip.focus(id, geometry) else { return }
        layout(animated: true)
        focusWindow(id)
    }

    private func popOut(_ id: WindowID) {
        guard !paused else { return }
        strip.ungroup(id, geometry)
        log("untab: \(summary())")
        layout(animated: true)
        focusWindow(id)
    }

    private func focusWindow(_ id: WindowID) {
        pendingFocus = (id, Date().addingTimeInterval(0.6))
        tracker.windows[id]?.focus()
    }

    /// One tab bar per group, sitting on top of the window that is showing.
    /// Follows `applied`, so it moves with glides too.
    private func updateTabBars() {
        guard !paused else { return tabBars.hideAll() }
        let g = geometry
        let bars: [TabBarModel] = strip.columns.filter(\.isTabbed).compactMap { column in
            guard let frame = applied[column.window], !isOffscreen(frame, g) else { return nil }
            let tabs = column.windows.map { id in
                TabBarModel.Tab(id: id, title: titles[id] ?? "", pid: tracker.windows[id]?.pid ?? 0)
            }
            let bar = CGRect(x: frame.minX, y: frame.minY - settings.tabBarHeight, width: frame.width, height: settings.tabBarHeight)
            return TabBarModel(frame: bar, tabs: tabs, active: column.active)
        }
        tabBars.show(bars)
    }

    /// Drag a window by its title bar over the middle of another and hold:
    /// "Add as Tab" appears, and letting go there makes the two a tab group.
    private func beginDrag(_ id: WindowID) {
        drag = (id, nil, Date())
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.trackDrag() }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func trackDrag() {
        guard let current = drag else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return endDrag() }
        let g = geometry
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)
        let source = strip.index(of: current.window)
        let under = strip.frames(g, sliver: settings.sliver, tabBarHeight: settings.tabBarHeight).first { frame in
            !frame.parked && !frame.tucked && strip.index(of: frame.window) != source
                && frame.rect.insetBy(dx: frame.rect.width / 4, dy: frame.rect.height / 4).contains(point)
        }
        if under?.window != current.target {
            drag = (current.window, under?.window, Date())
            dropHighlight.hide()
        } else if let under, !dropHighlight.isShowing, Date().timeIntervalSince(current.since) >= 0.35 {
            let grouped = strip.index(of: under.window).map { strip.columns[$0].isTabbed } ?? false
            let top = grouped ? settings.tabBarHeight : 0
            dropHighlight.show(over: CGRect(x: under.rect.minX, y: under.rect.minY - top,
                                            width: under.rect.width, height: under.rect.height + top))
        }
    }

    private func endDrag() {
        dragTimer?.invalidate()
        dragTimer = nil
        guard let finished = drag else { return }
        drag = nil
        let dropped = dropHighlight.isShowing
        dropHighlight.hide()
        // Dropped anywhere else: the usual snap-back puts the window home.
        guard dropped, let target = finished.target else { return }
        if let actual = tracker.windows[finished.window]?.frame {
            applied[finished.window] = actual
            canvas[finished.window] = actual
        }
        strip.group(finished.window, onto: target, geometry)
        log("tabbed \(describe(finished.window)) with \(describe(target)): \(summary())")
        layout(animated: true)
        focusWindow(finished.window)
    }

    // MARK: Window events

    func windowAppeared(_ window: AXWindow) {
        if discovered != nil {
            discovered?.append(window)
            return
        }
        guard !floating.contains(window.id), spaceOf[window.id] == nil else { return }
        let g = geometry
        let home = Spaces.space(of: window.id) ?? space
        spaceOf[window.id] = home
        strips[home, default: newStrip()].insert(window.id, width: initialWidth(window, g), g)
        log("+ \(describe(window.id)) on space \(home)")
        guard home == space else { return }
        if tracker.focusedWindowID() == window.id { strip.focus(window.id, g) }
        layout(animated: true)
    }

    func windowDisappeared(_ id: WindowID) {
        guard let home = spaceOf.removeValue(forKey: id) else { return }
        let g = geometry
        log("- window \(id)")
        strips[home]?.remove(id, g)
        applied[id] = nil
        canvas[id] = nil
        guard home == space else { return }
        if let focused = tracker.focusedWindowID(), strip.contains(focused) { strip.focus(focused, g) }
        layout(animated: true)
    }

    func windowFocused(_ id: WindowID) {
        if let pending = pendingFocus {
            if pending.until > Date(), pending.id != id { return }
            pendingFocus = nil
        }
        guard !paused, let home = spaceOf[id] else { return }
        let g = geometry
        // A window dragged to another Space joins that Space's strip.
        if let actual = Spaces.space(of: id), actual != home, let width = strips[home]?.width(of: id) {
            strips[home]?.remove(id, g)
            strips[actual, default: newStrip()].insert(id, width: width, g)
            spaceOf[id] = actual
        }
        guard spaceOf[id] == space else { return }
        // Usually just the echo of a focus change we made; nothing to move.
        let before = strip
        strip.focus(id, g)
        if strip != before { layout(animated: true) }
    }

    /// Coalesces move/resize reports. Ours match `applied` and are ignored;
    /// a width the user dragged to is adopted, anything else snaps back.
    func windowFrameChanged(_ id: WindowID) {
        // Moving under a held mouse button, and not by us: the user is dragging it.
        if drag == nil, !paused, animationTimer == nil, NSEvent.pressedMouseButtons & 1 != 0, strip.contains(id),
           let actual = tracker.windows[id]?.frame, let expected = applied[id],
           abs(actual.minX - expected.minX) > 2 || abs(actual.minY - expected.minY) > 2,
           abs(actual.width - expected.width) <= 2 {
            beginDrag(id)
        }
        changed.insert(id)
        changeCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcileChangedFrames() }
        changeCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func reconcileChangedFrames() {
        // Wait out our own animation and any drag still in progress.
        if animationTimer != nil || NSEvent.pressedMouseButtons != 0 {
            if let id = changed.first { windowFrameChanged(id) }
            return
        }
        let g = geometry
        var dirty = false
        for id in changed {
            guard strip.contains(id), let actual = tracker.windows[id]?.frame, let expected = applied[id] else { continue }
            if isOffscreen(expected, g) {
                // macOS may nudge a parked window; agree rather than fight it.
                applied[id] = actual
                continue
            }
            canvas[id] = actual
            if abs(actual.width - expected.width) > 2 {
                strip.setWidth(g.ratio(actual.width), of: id, g)
                log("width of \(id) kept at \(Int(actual.width))pt")
                dirty = true
            } else if abs(actual.minX - expected.minX) > 2 || abs(actual.minY - expected.minY) > 2
                        || abs(actual.height - expected.height) > 2 {
                dirty = true
            }
            applied[id] = actual
        }
        changed.removeAll()
        if dirty && !paused { layout(animated: true) }
    }

    // MARK: Layout

    /// Moves every window to its place in the strip: instantly, or gliding
    /// when smooth motion is on.
    func layout(animated: Bool) {
        guard !paused else { return }
        let g = geometry
        let glide = animated && smoothMotion && settings.animationDuration > 0
        // A second pass runs when an app refuses a width and the strip adopts it.
        for _ in 0..<3 {
            let changes = pendingChanges(g)
            // Windows trading places would have to pass through each other
            // mid-glide, so a swap snaps instead.
            if glide && !crossing(changes) {
                let goal = goalFrames(g)
                if animationTimer != nil, goal == animationGoal { break } // already heading there
                cancelAnimation()
                if !changes.isEmpty { animate(changes, goal, g) }
                break
            }
            cancelAnimation()
            if applyInOrder(changes, g) { break }
        }
        for column in strip.columns where column.isTabbed {
            for id in column.windows { titles[id] = tracker.windows[id]?.title }
        }
        updateTabBars()
        onUpdate()
        scheduleSave()
    }

    private func goalFrames(_ g: Geometry) -> [WindowID: CGRect] {
        Dictionary(strip.frames(g, sliver: settings.sliver, tabBarHeight: settings.tabBarHeight).map { ($0.window, $0.rect) }, uniquingKeysWith: { a, _ in a })
    }

    /// What has to move. Windows already in place just get their new canvas
    /// position recorded (one parked at an edge can move along the canvas
    /// without moving on screen).
    private func pendingChanges(_ g: Geometry) -> [Change] {
        strip.frames(g, sliver: settings.sliver, tabBarHeight: settings.tabBarHeight).compactMap { target in
            guard let window = tracker.windows[target.window] else { return nil }
            let from = applied[target.window] ?? window.frame ?? target.rect
            guard from != target.rect else {
                canvas[target.window] = target.unparked
                return nil
            }
            return Change(window: window, from: from, to: target.rect,
                          fromCanvas: canvas[target.window] ?? from, toCanvas: target.unparked)
        }
    }

    /// Snaps windows into place one at a time, always picking a window whose
    /// destination is clear of every window still waiting to move, so nothing
    /// lands on top of a neighbour. Returns false when an app refused a width
    /// and the strip adopted the real one, so the caller recomputes.
    private func applyInOrder(_ changes: [Change], _ g: Geometry) -> Bool {
        guard !changes.isEmpty else { return true }
        suspendEnhancedUI(for: changes)
        var pending = changes
        while !pending.isEmpty {
            guard let next = pending.firstIndex(where: { change in
                !pending.contains { other in other.id != change.id && overlaps(change.to, other.from, g) }
            }) else {
                // Two windows trading places block each other: step one aside
                // to the screen edge first, then carry on.
                let change = pending[0]
                let aside = CGRect(origin: CGPoint(x: g.viewport.maxX - settings.sliver, y: change.from.minY), size: change.from.size)
                change.window.setPosition(aside.origin)
                pending[0] = Change(window: change.window, from: aside, to: change.to,
                                    fromCanvas: change.fromCanvas, toCanvas: change.toCanvas)
                continue
            }
            let change = pending.remove(at: next)
            if !setFrame(change, g) { return false }
            canvas[change.id] = change.toCanvas
        }
        return true
    }

    /// Shrinks before moving and grows after, so a window never pokes into
    /// space its neighbour hasn't left yet.
    private func setFrame(_ change: Change, _ g: Geometry) -> Bool {
        let window = change.window, to = change.to
        guard change.from.size != to.size else {
            window.setPosition(to.origin)
            applied[window.id] = CGRect(origin: to.origin, size: change.from.size)
            return true
        }
        if to.width < change.from.width {
            window.setSize(to.size)
            window.setPosition(to.origin)
        } else {
            window.setPosition(to.origin)
            window.setSize(to.size)
        }
        return adopt(window, requested: to, previous: change.from, g)
    }

    /// Reads back a resized window. Retries a width macOS only partly applied
    /// near the screen edge (from Paneru), and keeps a width the app insists on
    /// (minimum sizes, character grids). Returns false if the strip changed.
    private func adopt(_ window: AXWindow, requested to: CGRect, previous: CGRect, _ g: Geometry) -> Bool {
        guard var actual = window.frame else { return true }
        if actual.width + 1 < to.width, actual.width > previous.width + 1 {
            window.setPosition(CGPoint(x: to.minX - (to.width - actual.width), y: to.minY))
            window.setSize(to.size)
            window.setPosition(to.origin)
            actual = window.frame ?? actual
        }
        applied[window.id] = actual
        guard abs(actual.width - to.width) > 1 else { return true }
        strip.setWidth(g.ratio(actual.width), of: window.id, g)
        log("\(describe(window.id)) keeps its own width of \(Int(actual.width))pt")
        return false
    }

    /// Glides the canvas: every window travels from its old to its new canvas
    /// position, and is parked at the edge only while it is wholly off screen.
    /// So windows keep their spacing and slide off the edge instead of
    /// catching up with each other. While moving, each window keeps the
    /// narrower of its old and new sizes (shrinking at the start, growing at
    /// the end), and every point between two non-overlapping layouts is
    /// non-overlapping too. Each frame moves windows in the order that keeps
    /// them clear of each other.
    private func animate(_ changes: [Change], _ goal: [WindowID: CGRect], _ g: Geometry) {
        suspendEnhancedUI(for: changes)
        // Switching tabs snaps: the old tab tucks away first, then the new one appears.
        let switching = changes.filter { isTucked($0.to, g) || isTucked($0.from, g) }
            .sorted { a, _ in isTucked(a.to, g) }
        for change in switching {
            _ = setFrame(change, g)
            canvas[change.id] = change.toCanvas
        }
        let moving = changes.filter { !isTucked($0.to, g) && !isTucked($0.from, g) }
        for change in moving {
            let small = smallSize(change)
            if small != change.from.size { change.window.setSize(small) }
        }
        let gliding = moving.sorted { a, b in
            let rightA = a.toCanvas.minX > a.fromCanvas.minX, rightB = b.toCanvas.minX > b.fromCanvas.minX
            if rightA != rightB { return rightA }
            return rightA ? a.fromCanvas.minX > b.fromCanvas.minX : a.fromCanvas.minX < b.fromCanvas.minX
        }
        animationGoal = goal
        let start = CACurrentMediaTime()
        let duration = settings.animationDuration
        let viewport = g.viewport, sliver = settings.sliver
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(1, (CACurrentMediaTime() - start) / duration)
            if t < 1 {
                let eased = 1 - pow(1 - t, 3)
                for change in gliding {
                    let at = CGRect(
                        x: (change.fromCanvas.minX + (change.toCanvas.minX - change.fromCanvas.minX) * eased).rounded(),
                        y: (change.fromCanvas.minY + (change.toCanvas.minY - change.fromCanvas.minY) * eased).rounded(),
                        width: self.smallSize(change).width, height: self.smallSize(change).height)
                    let shown = WindowFrame.park(at, in: viewport, sliver: sliver).rect
                    if shown.origin != self.applied[change.id]?.origin { change.window.setPosition(shown.origin) }
                    self.applied[change.id] = shown
                    self.canvas[change.id] = at
                }
                self.updateTabBars()
                return
            }
            timer.invalidate()
            self.animationTimer = nil
            self.animationGoal = nil
            var settled = true
            for change in gliding {
                change.window.setPosition(change.to.origin)
                self.canvas[change.id] = change.toCanvas
                if change.to.size == change.from.size {
                    self.applied[change.id] = change.to
                } else {
                    if change.to.size != self.smallSize(change) { change.window.setSize(change.to.size) }
                    settled = self.adopt(change.window, requested: change.to, previous: change.from, g) && settled
                }
            }
            self.updateTabBars()
            if !settled { self.layout(animated: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func crossing(_ changes: [Change]) -> Bool {
        let order = changes.sorted { $0.fromCanvas.minX < $1.fromCanvas.minX }
        return zip(order, order.dropFirst()).contains { $0.toCanvas.minX > $1.toCanvas.minX }
    }

    private func smallSize(_ change: Change) -> CGSize {
        CGSize(width: min(change.from.width, change.to.width), height: min(change.from.height, change.to.height))
    }

    private func cancelAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationGoal = nil
    }

    /// Whether two frames overlap on screen. A parked window's sliver doesn't count.
    private func overlaps(_ a: CGRect, _ b: CGRect, _ g: Geometry) -> Bool {
        guard let x = visibleSpan(a, g), let y = visibleSpan(b, g) else { return false }
        return x.lowerBound < y.upperBound && y.lowerBound < x.upperBound
    }

    private func visibleSpan(_ rect: CGRect, _ g: Geometry) -> ClosedRange<CGFloat>? {
        let lo = max(rect.minX, g.viewport.minX), hi = min(rect.maxX, g.viewport.maxX)
        return hi - lo > settings.sliver + 1 ? lo...hi : nil
    }

    /// Apps animate their own frame changes while AXEnhancedUserInterface is
    /// on. Keep it off while windows are moving and put it back once things
    /// have been still for a second (re-enabling makes Chromium apps rebuild
    /// their accessibility tree, so not after every keypress).
    private func suspendEnhancedUI(for changes: [Change]) {
        for pid in Set(changes.map(\.window.pid)) { AX.suspendEnhancedUI(pid) }
        enhancedUIRestore?.cancel()
        let work = DispatchWorkItem { AX.resumeEnhancedUI() }
        enhancedUIRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func isOffscreen(_ rect: CGRect, _ g: Geometry) -> Bool {
        let v = g.viewport
        return rect.maxX <= v.minX + settings.sliver + 1 || rect.minX >= v.maxX - settings.sliver - 1
    }

    /// Background tabs sit in the screen's bottom-right corner.
    private func isTucked(_ rect: CGRect, _ g: Geometry) -> Bool {
        rect.minX >= g.viewport.maxX - settings.sliver - 1 && rect.minY >= g.viewport.maxY - settings.sliver - 1
    }

    private func bringOnScreen(_ window: AXWindow, _ g: Geometry) {
        guard let frame = window.frame else { return }
        let v = g.viewport
        let x = frame.width >= v.width ? v.minX : min(max(frame.minX, v.minX), v.maxX - frame.width)
        let y = frame.height >= v.height ? v.minY : min(max(frame.minY, v.minY), v.maxY - frame.height)
        if x != frame.minX || y != frame.minY { window.setPosition(CGPoint(x: x, y: y)) }
    }

    /// Puts every window fully on screen, so nothing is left parked at an
    /// edge when Ribbon pauses or quits.
    func restoreAll() {
        cancelAnimation()
        tabBars.hideAll()
        let g = geometry
        for id in spaceOf.keys {
            if let window = tracker.windows[id] { bringOnScreen(window, g) }
        }
        AX.resumeEnhancedUI()
        saveNow()
    }

    // MARK: Startup and state

    private func initialWidth(_ window: AXWindow, _ g: Geometry) -> Double {
        settings.defaultWidth ?? window.frame.map { g.ratio($0.width) } ?? 0.5
    }

    /// Saved order and widths win for windows we have seen before; the rest
    /// join in their current left-to-right order, keeping their own widths.
    private func buildStrips(from windows: [AXWindow]) {
        let g = geometry
        let saved = loadState()
        var savedPlace: [WindowID: (index: Int, width: Double)] = [:]
        let savedColumns = saved?.spaces.values.flatMap(\.columns) ?? []
        for strip in saved?.spaces.values.map({ $0 }) ?? [] {
            for (index, column) in strip.columns.enumerated() {
                for id in column.windows { savedPlace[id] = (index, column.width) }
            }
        }
        let ids = Set(windows.map(\.id))
        floating = Set(saved?.floating ?? []).intersection(ids)
        let tiled = windows.filter { !floating.contains($0.id) }
        let bySpace = Dictionary(grouping: tiled) { Spaces.space(of: $0.id) ?? space }
        for (home, members) in bySpace {
            let ordered = members.sorted { a, b in
                switch (savedPlace[a.id], savedPlace[b.id]) {
                case let (pa?, pb?): return pa.index < pb.index
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return (a.frame?.minX ?? 0) < (b.frame?.minX ?? 0)
                }
            }
            var strip = newStrip()
            for window in ordered {
                strip.insert(window.id, width: savedPlace[window.id]?.width ?? initialWidth(window, g), at: strip.count, g)
                spaceOf[window.id] = home
            }
            for column in savedColumns where column.isTabbed {
                let members = column.windows.filter { strip.contains($0) }
                for id in members.dropFirst() { strip.group(id, onto: members[0], g) }
                if members.contains(column.window) { strip.focus(column.window, g) }
            }
            if !strip.isEmpty { strip.focus(index: 0, g) }
            strips[home] = strip
        }
        if let focused = tracker.focusedWindowID(), strip.contains(focused) {
            strip.focus(focused, g)
        }
    }

    private func loadState() -> SavedState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    func saveNow() {
        let spaces = Dictionary(uniqueKeysWithValues: strips.filter { !$0.value.isEmpty }.map { (String($0.key), $0.value) })
        let state = SavedState(spaces: spaces, floating: Array(floating))
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            log("could not save state: \(error)")
        }
    }

    // MARK: Diagnostics

    private func describe(_ id: WindowID) -> String {
        guard let window = tracker.windows[id] else { return "window \(id)" }
        let app = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "?"
        return "\(app) “\(window.title)” #\(id)"
    }

    func summary() -> String {
        let g = geometry
        let visible = Set(strip.fullyVisible(g))
        let columns = strip.columns.enumerated().map { i, c in
            let mark = i == strip.focusedIndex ? "*" : (visible.contains(i) ? "" : "~")
            let ids = c.isTabbed ? "(" + c.windows.map { $0 == c.window ? "\($0)^" : "\($0)" }.joined(separator: " ") + ")" : "\(c.window)"
            return "\(mark)\(ids):\(String(format: "%.2f", c.width))"
        }
        return "scroll=\(Int(strip.scroll)) [\(columns.joined(separator: " "))]"
    }

    private func dump() {
        log("space \(space) strip \(summary())  (* focused, ~ not fully visible)")
        for (other, strip) in strips where other != space && !strip.isEmpty {
            log("  space \(other): \(strip.count) windows")
        }
        let frames = Dictionary(strip.frames(geometry, sliver: settings.sliver, tabBarHeight: settings.tabBarHeight).map { ($0.window, $0) }, uniquingKeysWith: { a, _ in a })
        for id in strip.windows {
            let actual = tracker.windows[id]?.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
            let target = frames[id].map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))\($0.parked ? " parked" : "")" } ?? "?"
            log("  \(describe(id))  target \(target)  actual \(actual)")
        }
    }
}
