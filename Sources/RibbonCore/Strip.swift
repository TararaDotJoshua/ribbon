import CoreGraphics
import Foundation

public typealias WindowID = UInt32

public enum Direction: Sendable {
    case left, right
}

/// One column of the strip. Widths are ratios of the viewport so a column
/// keeps its proportion across displays, and only changes when asked to.
/// A column with several windows is a tab group: one shows, the rest are tucked away.
public struct Column: Codable, Equatable, Sendable {
    public var windows: [WindowID]
    public var active: Int
    public var width: Double
    /// The width to go back to when "fill" is toggled off.
    public var restoreWidth: Double?

    public init(window: WindowID, width: Double, restoreWidth: Double? = nil) {
        self.windows = [window]
        self.active = 0
        self.width = width
        self.restoreWidth = restoreWidth
    }

    /// The window showing.
    public var window: WindowID { windows[active] }
    public var isTabbed: Bool { windows.count > 1 }

    private enum CodingKeys: String, CodingKey { case windows, active, width, restoreWidth, window }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Before tab groups a column held a single "window".
        windows = try c.decodeIfPresent([WindowID].self, forKey: .windows) ?? [c.decode(WindowID.self, forKey: .window)]
        active = min(try c.decodeIfPresent(Int.self, forKey: .active) ?? 0, windows.count - 1)
        width = try c.decode(Double.self, forKey: .width)
        restoreWidth = try c.decodeIfPresent(Double.self, forKey: .restoreWidth)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(windows, forKey: .windows)
        try c.encode(active, forKey: .active)
        try c.encode(width, forKey: .width)
        try c.encodeIfPresent(restoreWidth, forKey: .restoreWidth)
    }
}

/// The screen area the strip is shown through, in Accessibility (top-left) coordinates.
public struct Geometry: Equatable, Sendable {
    public var viewport: CGRect
    public var gap: Double

    public init(viewport: CGRect, gap: Double) {
        self.viewport = viewport
        self.gap = gap
    }

    /// Width between the outer gaps.
    public var contentWidth: Double { viewport.width - 2 * gap }

    /// Pixel width of a column. Chosen so that n columns of ratio 1/n, plus
    /// the gaps between and around them, exactly fill the viewport.
    public func pixels(_ ratio: Double) -> Double {
        (ratio * (viewport.width - gap) - gap).rounded()
    }

    /// Inverse of `pixels`.
    public func ratio(_ pixels: Double) -> Double {
        (pixels + gap) / (viewport.width - gap)
    }
}

/// Where a window should go. `parked` windows are wholly outside the viewport
/// and sit at its edge with a sliver showing, since macOS will not place a
/// window entirely off-screen.
public struct WindowFrame: Equatable, Sendable {
    public var window: WindowID
    public var rect: CGRect
    public var parked: Bool
    /// Where the window sits on the canvas before parking, possibly far off-screen.
    public var unparked: CGRect
    /// A background tab, tucked into the screen's bottom-right corner.
    public var tucked: Bool

    public init(window: WindowID, rect: CGRect, parked: Bool, unparked: CGRect, tucked: Bool = false) {
        self.window = window
        self.rect = rect
        self.parked = parked
        self.unparked = unparked
        self.tucked = tucked
    }

    /// Where a window at canvas position `rect` is actually put: as is when
    /// any of it is on screen, otherwise parked at the nearer edge.
    public static func park(_ rect: CGRect, in viewport: CGRect, sliver: Double) -> (rect: CGRect, parked: Bool) {
        var r = rect
        if rect.maxX <= viewport.minX {
            r.origin.x = viewport.minX - rect.width + sliver
        } else if rect.minX >= viewport.maxX {
            r.origin.x = viewport.maxX - sliver
        } else {
            return (rect, false)
        }
        return (r, true)
    }
}

/// An endless horizontal row of columns seen through a viewport. `scroll` is
/// the canvas x shown at the viewport's left content edge; it is unbounded,
/// so the canvas can be panned anywhere.
public struct Strip: Codable, Equatable, Sendable {
    public private(set) var columns: [Column] = []
    public private(set) var focusedIndex: Int?
    public var scroll: Double = 0
    public var minWidth: Double = 0.1
    public var maxWidth: Double = 1.0

    private static let epsilon = 0.5

    public init() {}

    // MARK: Queries

    public var isEmpty: Bool { columns.isEmpty }
    public var count: Int { columns.count }
    /// Every window, background tabs included.
    public var windows: [WindowID] { columns.flatMap(\.windows) }

    public var focusedWindow: WindowID? {
        focusedIndex.map { columns[$0].window }
    }

    /// The column holding `window`, as the showing tab or a background one.
    public func index(of window: WindowID) -> Int? {
        columns.firstIndex { $0.windows.contains(window) }
    }

    public func contains(_ window: WindowID) -> Bool {
        index(of: window) != nil
    }

    public func width(of window: WindowID) -> Double? {
        index(of: window).map { columns[$0].width }
    }

    /// Left canvas x of every column, plus each column's pixel width.
    public func layout(_ g: Geometry) -> [(x: Double, width: Double)] {
        var x = 0.0
        return columns.map { column in
            let w = g.pixels(column.width)
            defer { x += w + g.gap }
            return (x, w)
        }
    }

    public func totalWidth(_ g: Geometry) -> Double {
        guard let last = layout(g).last else { return 0 }
        return last.x + last.width
    }

    /// Indices of the columns wholly inside the viewport.
    public func fullyVisible(_ g: Geometry) -> [Int] {
        let right = scroll + g.contentWidth
        return layout(g).enumerated().compactMap { i, c in
            c.x >= scroll - Self.epsilon && c.x + c.width <= right + Self.epsilon ? i : nil
        }
    }

    // MARK: Membership

    /// Inserts a column, by default just after the focused one. Focus stays
    /// where it is; the caller focuses the new window when the OS reports it.
    public mutating func insert(_ window: WindowID, width: Double, at position: Int? = nil, _ g: Geometry) {
        guard !contains(window) else { return }
        let index = min(max(position ?? (focusedIndex.map { $0 + 1 } ?? columns.count), 0), columns.count)
        let x = index < columns.count ? layout(g)[index].x : totalWidth(g) + (columns.isEmpty ? 0 : g.gap)
        columns.insert(Column(window: window, width: clamp(width)), at: index)
        if let f = focusedIndex, f >= index { focusedIndex = f + 1 }
        // Inserting left of the viewport would shove everything on screen
        // right; scroll along so the visible windows stay put.
        if x < scroll - Self.epsilon {
            scroll += g.pixels(columns[index].width) + g.gap
        }
    }

    public mutating func remove(_ window: WindowID, _ g: Geometry) {
        guard let index = index(of: window) else { return }
        if columns[index].isTabbed {
            removeTab(window, from: index)
            return
        }
        let c = layout(g)[index]
        columns.remove(at: index)
        if c.x + c.width <= scroll + Self.epsilon {
            scroll -= c.width + g.gap
        }
        if let f = focusedIndex {
            if columns.isEmpty {
                focusedIndex = nil
            } else if f > index || f == columns.count {
                focusedIndex = f - 1
            }
        }
        settle(g)
    }

    // MARK: Focus and navigation

    /// Focuses a window and scrolls just enough to show it whole.
    /// Focusing a background tab makes it the one showing.
    @discardableResult
    public mutating func focus(_ window: WindowID, _ g: Geometry) -> Bool {
        guard let index = index(of: window) else { return false }
        columns[index].active = columns[index].windows.firstIndex(of: window) ?? columns[index].active
        focus(index: index, g)
        return true
    }

    public mutating func focus(index: Int, _ g: Geometry) {
        guard !columns.isEmpty else { return }
        let i = min(max(index, 0), columns.count - 1)
        focusedIndex = i
        ensureVisible(i, g)
    }

    /// Ctrl+Left / Ctrl+Right: the neighbouring window.
    public mutating func focusNeighbour(_ direction: Direction, _ g: Geometry) {
        guard !columns.isEmpty else { return }
        guard let f = focusedIndex else {
            focus(index: fullyVisible(g).first ?? 0, g)
            return
        }
        focus(index: f + (direction == .right ? 1 : -1), g)
    }

    /// The next set of windows: the first column not fully visible in that
    /// direction moves to the opposite edge, clamped to the strip's ends.
    public mutating func page(_ direction: Direction, _ g: Geometry) {
        guard !columns.isEmpty else { return }
        let cols = layout(g)
        let left = scroll, right = scroll + g.contentWidth
        switch direction {
        case .right:
            guard let j = cols.firstIndex(where: { $0.x + $0.width > right + Self.epsilon }) else {
                focus(index: columns.count - 1, g)
                return
            }
            let end = cols[cols.count - 1].x + cols[cols.count - 1].width
            scroll = min(cols[j].x, max(end - g.contentWidth, scroll))
            focusedIndex = j
        case .left:
            guard let p = cols.lastIndex(where: { $0.x < left - Self.epsilon }) else {
                focus(index: 0, g)
                return
            }
            let c = cols[p]
            scroll = c.width > g.contentWidth ? c.x : max(c.x + c.width - g.contentWidth, min(0, scroll))
            focusedIndex = p
        }
    }

    /// Scrolls the minimum distance that shows column `index` whole.
    /// A column wider than the viewport is aligned to the left edge.
    public mutating func ensureVisible(_ index: Int, _ g: Geometry) {
        guard columns.indices.contains(index) else { return }
        let c = layout(g)[index]
        if c.width >= g.contentWidth || c.x < scroll {
            scroll = c.x
        } else if c.x + c.width > scroll + g.contentWidth {
            scroll = c.x + c.width - g.contentWidth
        }
    }

    public mutating func centerFocused(_ g: Geometry) {
        guard let f = focusedIndex else { return }
        let c = layout(g)[f]
        scroll = (c.x + c.width / 2 - g.contentWidth / 2).rounded()
    }

    /// Free panning of the canvas (scroll wheel). Unbounded on purpose.
    public mutating func pan(by dx: Double) {
        scroll += dx
    }

    /// Swaps the focused column with its neighbour.
    public mutating func moveFocused(_ direction: Direction, _ g: Geometry) {
        guard let f = focusedIndex else { return }
        let t = f + (direction == .right ? 1 : -1)
        guard columns.indices.contains(t) else { return }
        columns.swapAt(f, t)
        focusedIndex = t
        ensureVisible(t, g)
    }

    /// Re-anchors after the strip shrank: keeps the focused column in view
    /// and pulls back any empty space left past either end.
    public mutating func settle(_ g: Geometry) {
        guard !columns.isEmpty else {
            scroll = 0
            return
        }
        let total = totalWidth(g)
        if total <= g.contentWidth {
            scroll = 0
        } else {
            scroll = min(max(scroll, 0), total - g.contentWidth)
        }
        if let f = focusedIndex { ensureVisible(f, g) }
    }

    // MARK: Tab groups

    /// Makes `window` a tab of the column holding `target`, and shows it.
    /// The group keeps the target column's width.
    public mutating func group(_ window: WindowID, onto target: WindowID, _ g: Geometry) {
        guard window != target, let from = index(of: window), let to = index(of: target), from != to else { return }
        remove(window, g)
        guard let t = index(of: target) else { return }
        columns[t].windows.insert(window, at: columns[t].active + 1)
        columns[t].active += 1
        focusedIndex = t
        ensureVisible(t, g)
    }

    /// Ctrl+Alt+[ / ]: the focused window joins the neighbouring column as a tab.
    public mutating func joinNeighbour(_ direction: Direction, _ g: Geometry) {
        guard let f = focusedIndex else { return }
        let n = f + (direction == .right ? 1 : -1)
        guard columns.indices.contains(n) else { return }
        group(columns[f].window, onto: columns[n].window, g)
    }

    /// Takes a tab out of its group into its own column, just right of the
    /// group and the same width.
    public mutating func ungroup(_ window: WindowID, _ g: Geometry) {
        guard let i = index(of: window), columns[i].isTabbed else { return }
        let width = columns[i].width
        removeTab(window, from: i)
        columns.insert(Column(window: window, width: width), at: i + 1)
        focusedIndex = i + 1
        ensureVisible(i + 1, g)
    }

    /// Ctrl+Alt+Up / Down: the previous / next tab of the focused group, wrapping.
    public mutating func cycleTab(_ direction: Direction) {
        guard let f = focusedIndex, columns[f].isTabbed else { return }
        let n = columns[f].windows.count
        columns[f].active = (columns[f].active + (direction == .right ? 1 : n - 1)) % n
    }

    private mutating func removeTab(_ window: WindowID, from index: Int) {
        guard let k = columns[index].windows.firstIndex(of: window) else { return }
        columns[index].windows.remove(at: k)
        if columns[index].active > k || columns[index].active >= columns[index].windows.count {
            columns[index].active = max(columns[index].active - 1, 0)
        }
    }

    // MARK: Widths

    public mutating func setWidth(_ ratio: Double, of window: WindowID, _ g: Geometry) {
        guard let i = index(of: window) else { return }
        columns[i].width = clamp(ratio)
        columns[i].restoreWidth = nil
        if i == focusedIndex { ensureVisible(i, g) }
    }

    /// Steps the focused column through `presets`. `wrap` cycles past the
    /// ends instead of stopping at them.
    public mutating func stepPreset(_ direction: Direction, presets: [Double], wrap: Bool, _ g: Geometry) {
        guard let f = focusedIndex else { return }
        let sorted = presets.map(clamp).sorted()
        guard let first = sorted.first, let last = sorted.last else { return }
        let current = columns[f].width
        let next: Double?
        switch direction {
        case .right: next = sorted.first { $0 > current + 0.01 } ?? (wrap ? first : nil)
        case .left: next = sorted.last { $0 < current - 0.01 } ?? (wrap ? last : nil)
        }
        guard let next else { return }
        setWidth(next, of: columns[f].window, g)
    }

    public mutating func nudgeWidth(by delta: Double, _ g: Geometry) {
        guard let f = focusedIndex else { return }
        setWidth(columns[f].width + delta, of: columns[f].window, g)
    }

    /// Fills the viewport with the focused column, or puts its width back.
    public mutating func toggleFill(_ g: Geometry) {
        guard let f = focusedIndex else { return }
        if let previous = columns[f].restoreWidth {
            columns[f].width = previous
            columns[f].restoreWidth = nil
        } else {
            columns[f].restoreWidth = columns[f].width
            columns[f].width = maxWidth
        }
        ensureVisible(f, g)
    }

    // MARK: Frames

    /// Target frame for every window. Columns fill the viewport's height; a
    /// tab group leaves `tabBarHeight` at the top for its tab bar, and its
    /// background tabs are tucked into the bottom-right corner.
    public func frames(_ g: Geometry, sliver: Double, tabBarHeight: Double = 0) -> [WindowFrame] {
        let v = g.viewport
        let y = v.minY + g.gap
        let height = v.height - 2 * g.gap
        var frames: [WindowFrame] = []
        for (column, c) in zip(columns, layout(g)) {
            let bar = column.isTabbed ? tabBarHeight : 0
            let unparked = CGRect(x: (v.minX + g.gap + c.x - scroll).rounded(), y: y + bar, width: c.width, height: height - bar)
            let placed = WindowFrame.park(unparked, in: v, sliver: sliver)
            for (i, window) in column.windows.enumerated() {
                if i == column.active {
                    frames.append(WindowFrame(window: window, rect: placed.rect, parked: placed.parked, unparked: unparked))
                } else {
                    let tuck = CGRect(x: v.maxX - sliver, y: v.maxY - sliver, width: c.width, height: height - bar)
                    frames.append(WindowFrame(window: window, rect: tuck, parked: true, unparked: tuck, tucked: true))
                }
            }
        }
        return frames
    }

    private func clamp(_ ratio: Double) -> Double {
        min(max(ratio, minWidth), maxWidth)
    }
}
