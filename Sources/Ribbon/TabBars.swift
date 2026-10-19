import AppKit
import RibbonCore

/// What one tab bar shows, and where (AX coordinates).
struct TabBarModel {
    struct Tab: Equatable {
        let id: WindowID
        let title: String
        let pid: pid_t
    }
    var frame: CGRect
    var tabs: [Tab]
    var active: Int
}

/// The strips of tabs above tab groups: one borderless, non-activating panel
/// per group, so clicking a tab never takes focus away from the windows.
final class TabBars {
    var onSelect: (WindowID) -> Void = { _ in }
    var onPopOut: (WindowID) -> Void = { _ in }
    var onClose: (WindowID) -> Void = { _ in }
    private var panels: [TabBarPanel] = []

    func show(_ bars: [TabBarModel]) {
        while panels.count < bars.count { panels.append(TabBarPanel(owner: self)) }
        for (panel, bar) in zip(panels, bars) { panel.show(bar) }
        for panel in panels.dropFirst(bars.count) where panel.isVisible { panel.orderOut(nil) }
    }

    func hideAll() {
        show([])
    }
}

private final class TabBarPanel: NSPanel {
    private let bar: TabBarView

    init(owner: TabBars) {
        bar = TabBarView(owner: owner)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .normal
        // Follow the user to whichever Space is showing; stay out of ⌘` and Mission Control.
        collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .transient]
        contentView = bar
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ model: TabBarModel) {
        if bar.tabs != model.tabs || bar.active != model.active {
            bar.tabs = model.tabs
            bar.active = model.active
            bar.needsDisplay = true
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let r = model.frame
        let frame = NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        if self.frame != frame { setFrame(frame, display: true) }
        if !isVisible { orderFrontRegardless() }
    }
}

private final class TabBarView: NSView {
    var tabs: [TabBarModel.Tab] = []
    var active = 0
    private unowned let owner: TabBars
    private var pressed: Int?
    private var pressPoint: NSPoint = .zero
    private var poppedOut = false
    private var hovered: Int?
    private var icons: [pid_t: NSImage] = [:]

    init(owner: TabBars) {
        self.owner = owner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func tabRect(_ i: Int) -> NSRect {
        let width = bounds.width / CGFloat(max(tabs.count, 1))
        return NSRect(x: width * CGFloat(i), y: 0, width: width, height: bounds.height).insetBy(dx: 2, dy: 3)
    }

    private func tab(at point: NSPoint) -> Int? {
        tabs.indices.first { tabRect($0).insetBy(dx: -2, dy: -3).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (i, tab) in tabs.enumerated() {
            let r = tabRect(i)
            let isActive = i == active
            if isActive {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            } else if i == hovered {
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            if i > 0, !isActive, i - 1 != active {
                NSColor.separatorColor.setFill()
                NSRect(x: r.minX - 2.5, y: r.minY + 4, width: 1, height: r.height - 8).fill()
            }
            var textX = r.minX + 8
            if let icon = icon(for: tab.pid) {
                let size: CGFloat = 16
                icon.draw(in: NSRect(x: r.minX + 8, y: r.midY - size / 2, width: size, height: size))
                textX += size + 6
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let title = tab.title.isEmpty ? (NSRunningApplication(processIdentifier: tab.pid)?.localizedName ?? "Window") : tab.title
            let textHeight = NSFont.systemFont(ofSize: 12).boundingRectForFont.height
            NSAttributedString(string: title, attributes: attributes)
                .draw(in: NSRect(x: textX, y: r.midY - textHeight / 2, width: max(r.maxX - textX - 8, 0), height: textHeight))
        }
    }

    private func icon(for pid: pid_t) -> NSImage? {
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        pressPoint = convert(event.locationInWindow, from: nil)
        pressed = tab(at: pressPoint)
        poppedOut = false
    }

    /// Pulling a tab well away from the bar takes it out of the group.
    override func mouseDragged(with event: NSEvent) {
        guard let pressed, !poppedOut else { return }
        let point = convert(event.locationInWindow, from: nil)
        if abs(point.y - pressPoint.y) > 24 || !bounds.insetBy(dx: -24, dy: -24).contains(point) {
            poppedOut = true
            owner.onPopOut(tabs[pressed].id)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, !poppedOut, tab(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        owner.onSelect(tabs[pressed].id)
    }

    override func mouseMoved(with event: NSEvent) {
        let now = tab(at: convert(event.locationInWindow, from: nil))
        if now != hovered {
            hovered = now
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let i = tab(at: convert(event.locationInWindow, from: nil)) else { return }
        let id = tabs[i].id
        let menu = NSMenu()
        menu.addItem(MenuAction("Show Tab") { [owner] in owner.onSelect(id) })
        menu.addItem(MenuAction("Move Out of Group") { [owner] in owner.onPopOut(id) })
        menu.addItem(.separator())
        menu.addItem(MenuAction("Close Window") { [owner] in owner.onClose(id) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// A menu item that runs a closure.
private final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// "Add as Tab": shown over a window while another is held above its middle.
final class DropHighlight {
    private let panel: NSPanel
    private(set) var isShowing = false

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .transient]
        panel.contentView = HighlightView()
    }

    func show(over rect: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrame(NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height), display: true)
        panel.orderFrontRegardless()
        isShowing = true
    }

    func hide() {
        guard isShowing else { return }
        panel.orderOut(nil)
        isShowing = false
    }
}

private final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 12, yRadius: 12)
        accent.withAlphaComponent(0.16).setFill()
        outline.fill()
        outline.lineWidth = 3
        accent.withAlphaComponent(0.9).setStroke()
        outline.stroke()

        let label = NSAttributedString(string: "Add as Tab", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        let pill = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 9,
                          width: size.width + 32, height: size.height + 18)
        accent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 16, y: pill.minY + 9))
    }
}
