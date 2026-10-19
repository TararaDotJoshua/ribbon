import CoreGraphics
import Foundation
import Testing
@testable import RibbonCore

/// 1000pt wide, no gaps: a ratio of 0.5 is exactly 500pt.
private let g = Geometry(viewport: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 0)

private func strip(_ widths: [Double], focus: Int? = 0) -> Strip {
    var s = Strip()
    for (i, w) in widths.enumerated() {
        s.insert(WindowID(i + 1), width: w, at: i, g)
    }
    if let focus { s.focus(index: focus, g) }
    return s
}

@Test func columnPixelsFillViewportWithGaps() {
    let gapped = Geometry(viewport: CGRect(x: 0, y: 0, width: 1010, height: 800), gap: 10)
    #expect(gapped.pixels(0.5) == 490)
    #expect(2 * gapped.pixels(0.5) + 3 * 10 == 1010)
    #expect(gapped.pixels(1.0) == gapped.contentWidth)
    #expect(abs(gapped.ratio(gapped.pixels(0.5)) - 0.5) < 1e-9)
}

@Test func focusNeighbourScrollsOnlyAsFarAsNeeded() {
    var s = strip([0.5, 0.5, 0.5, 0.5])
    #expect(s.scroll == 0)
    s.focusNeighbour(.right, g)
    #expect(s.focusedIndex == 1)
    #expect(s.scroll == 0)          // already whole on screen
    s.focusNeighbour(.right, g)
    #expect(s.focusedIndex == 2)
    #expect(s.scroll == 500)        // revealed at the right edge
    s.focusNeighbour(.left, g)
    #expect(s.focusedIndex == 1)
    #expect(s.scroll == 500)        // still visible, no scroll
    s.focusNeighbour(.left, g)
    #expect(s.scroll == 0)
    s.focusNeighbour(.left, g)
    #expect(s.focusedIndex == 0)    // clamps at the end
}

@Test func pageRightAndLeftMoveWholeSets() {
    var s = strip([0.5, 0.5, 0.5, 0.5, 0.5, 0.5])
    #expect(s.fullyVisible(g) == [0, 1])
    s.page(.right, g)
    #expect(s.scroll == 1000)
    #expect(s.focusedIndex == 2)
    #expect(s.fullyVisible(g) == [2, 3])
    s.page(.right, g)
    #expect(s.focusedIndex == 4)
    #expect(s.fullyVisible(g) == [4, 5])
    s.page(.right, g)                // nothing further: stay on the last
    #expect(s.focusedIndex == 5)
    #expect(s.scroll == 2000)

    s.page(.left, g)
    #expect(s.fullyVisible(g) == [2, 3])
    #expect(s.focusedIndex == 3)    // nearest the set we came from
    s.page(.left, g)
    #expect(s.fullyVisible(g) == [0, 1])
    #expect(s.focusedIndex == 1)
    s.page(.left, g)
    #expect(s.focusedIndex == 0)
    #expect(s.scroll == 0)
}

@Test func pagesStopAtTheStripEnds() {
    var s = strip([0.5, 0.5, 0.5, 0.5, 0.5])
    s.page(.right, g)
    s.page(.right, g)                // column 4 alone would leave a blank half
    #expect(s.scroll == 1500)
    #expect(s.focusedIndex == 4)
    #expect(s.fullyVisible(g) == [3, 4])
    s.page(.left, g)
    #expect(s.fullyVisible(g) == [1, 2])
    s.page(.left, g)                 // column 0 alone would leave a blank half
    #expect(s.scroll == 0)
    #expect(s.focusedIndex == 0)
}

@Test func pagingRespectsMixedWidths() {
    var s = strip([1.0 / 3, 1.0 / 3, 1.0 / 3, 2.0 / 3, 1.0 / 3])
    #expect(s.fullyVisible(g) == [0, 1, 2])
    s.page(.right, g)
    #expect(s.focusedIndex == 3)
    #expect(s.fullyVisible(g) == [3, 4])
}

@Test func partlyVisibleColumnLeadsTheNextPage() {
    var s = strip([0.6, 0.6, 0.6])
    s.page(.right, g)
    #expect(s.scroll == 600)
    #expect(s.focusedIndex == 1)
}

@Test func widthsAreKeptWhenWindowsComeAndGo() {
    var s = strip([0.4, 0.7, 0.25], focus: 1)
    s.insert(99, width: 0.5, g)
    #expect(s.windows == [1, 2, 99, 3])  // lands after the focused column
    #expect(s.columns.map(\.width) == [0.4, 0.7, 0.5, 0.25])
    s.remove(2, g)
    #expect(s.columns.map(\.width) == [0.4, 0.5, 0.25])
    #expect(s.focusedWindow == 99)      // the column that slid into its place
}

@Test func removingTheLastFocusedColumnFocusesItsLeftNeighbour() {
    var s = strip([0.5, 0.5, 0.5], focus: 2)
    s.remove(3, g)
    #expect(s.focusedWindow == 2)
    #expect(s.scroll == 0)              // everything fits again
}

@Test func insertingOffscreenLeftKeepsVisibleWindowsStill() {
    var s = strip([0.5, 0.5, 0.5, 0.5], focus: 3)
    let before = s.frames(g, sliver: 5).filter { !$0.parked }
    s.insert(42, width: 0.5, at: 0, g)
    let after = s.frames(g, sliver: 5).filter { !$0.parked }
    #expect(before == after)
}

@Test func presetsStepAndCycle() {
    let presets = [1.0 / 3, 0.5, 2.0 / 3, 1.0]
    var s = strip([0.5])
    s.stepPreset(.right, presets: presets, wrap: false, g)
    #expect(abs(s.columns[0].width - 2.0 / 3) < 1e-9)
    s.stepPreset(.right, presets: presets, wrap: false, g)
    #expect(s.columns[0].width == 1.0)
    s.stepPreset(.right, presets: presets, wrap: false, g)
    #expect(s.columns[0].width == 1.0)  // no wrap
    s.stepPreset(.right, presets: presets, wrap: true, g)
    #expect(abs(s.columns[0].width - 1.0 / 3) < 1e-9)
    s.stepPreset(.left, presets: presets, wrap: false, g)
    #expect(abs(s.columns[0].width - 1.0 / 3) < 1e-9)
}

@Test func nudgeClampsToLimits() {
    var s = strip([0.12])
    s.nudgeWidth(by: -0.05, g)
    #expect(s.columns[0].width == s.minWidth)
    s.nudgeWidth(by: 5, g)
    #expect(s.columns[0].width == s.maxWidth)
}

@Test func toggleFillRestoresWidth() {
    var s = strip([0.4, 0.5], focus: 1)
    s.toggleFill(g)
    #expect(s.columns[1].width == 1.0)
    #expect(s.scroll == 400)            // filled column aligned to the viewport
    s.toggleFill(g)
    #expect(s.columns[1].width == 0.5)
}

@Test func offscreenWindowsParkAtTheEdges() {
    var s = strip([0.75, 0.75, 0.75])
    var f = s.frames(g, sliver: 5)
    #expect(f.map(\.parked) == [false, false, true])
    #expect(f[1].rect.minX == 750)      // partly visible stays put
    #expect(f[2].rect.minX == 995)      // right sliver
    s.focus(index: 2, g)
    f = s.frames(g, sliver: 5)
    #expect(f[0].parked)
    #expect(f[0].rect.maxX == 5)        // left sliver
}

@Test func centerAndPanAreUnbounded() {
    var s = strip([0.3])
    s.centerFocused(g)
    #expect(s.scroll == -350)
    s.pan(by: -10_000)
    #expect(s.scroll == -10_350)
    s.focus(index: 0, g)
    #expect(s.scroll == -700)           // minimal scroll: arrives at the right edge
}

@Test func moveSwapsWithNeighbour() {
    var s = strip([0.3, 0.4, 0.5], focus: 0)
    s.moveFocused(.right, g)
    #expect(s.windows == [2, 1, 3])
    #expect(s.focusedWindow == 1)
}

@Test func keyCombosParse() {
    let c = KeyCombo("ctrl+shift+left")
    #expect(c?.keyCode == 123)
    #expect(c?.modifiers == [.control, .shift])
    #expect(KeyCombo("Control + Alt + R") == KeyCombo(keyCode: 15, modifiers: [.control, .option]))
    #expect(KeyCombo("ctrl+hyper") == nil)
    #expect(KeyCombo("ctrl") == nil)
    for (combo, command) in Settings.defaultBindings {
        #expect(KeyCombo(combo) != nil, "bad default combo \(combo)")
        #expect(Command(rawValue: command) != nil, "bad default command \(command)")
    }
}

@Test func settingsDecodeWithDefaults() throws {
    let json = #"{"gap": 12, "bindings": {"ctrl+left": "none", "cmd+alt+j": "focus-left"}}"#
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.gap == 12)
    #expect(s.widthPresets.count == 4)
    #expect(s.effectiveBindings["ctrl+left"] == nil)
    #expect(s.effectiveBindings["cmd+alt+j"] == "focus-left")
    #expect(s.effectiveBindings["ctrl+right"] == "focus-right")
}

// MARK: Tab groups

@Test func groupingMakesOneColumnShowingTheNewTab() {
    var s = strip([0.3, 0.4, 0.5], focus: 0)
    s.joinNeighbour(.right, g)
    #expect(s.columns.count == 2)
    #expect(s.columns[0].windows == [2, 1])
    #expect(s.columns[0].window == 1)          // the joining window shows
    #expect(s.columns[0].width == 0.4)         // the group keeps the target's width
    #expect(s.focusedWindow == 1)
}

@Test func backgroundTabsAreTuckedAndTheBarIsReserved() {
    var s = strip([0.5, 0.5], focus: 0)
    s.joinNeighbour(.right, g)
    let f = s.frames(g, sliver: 5, tabBarHeight: 28)
    let showing = f.first { $0.window == 1 }!
    let tucked = f.first { $0.window == 2 }!
    #expect(showing.rect.minY == 28 && showing.rect.height == 772)
    #expect(!showing.tucked)
    #expect(tucked.tucked && tucked.rect.minX == 995 && tucked.rect.minY == 795)
}

@Test func focusingABackgroundTabShowsIt() {
    var s = strip([0.5, 0.5], focus: 0)
    s.joinNeighbour(.right, g)
    s.focus(2, g)
    #expect(s.columns[0].window == 2)
    s.cycleTab(.right)
    #expect(s.columns[0].window == 1)
    s.cycleTab(.left)
    #expect(s.columns[0].window == 2)
}

@Test func closingTabsDissolvesTheGroup() {
    var s = strip([0.5, 0.5, 0.5], focus: 0)
    s.joinNeighbour(.right, g)                 // [1,2] [3]
    s.remove(1, g)
    #expect(s.columns.count == 2)
    #expect(s.columns[0].windows == [2])
    #expect(!s.columns[0].isTabbed)
}

@Test func untabPutsTheWindowBesideItsGroup() {
    var s = strip([0.5, 0.25], focus: 0)
    s.joinNeighbour(.right, g)                 // [2,1]
    s.ungroup(1, g)
    #expect(s.columns.map(\.windows) == [[2], [1]])
    #expect(s.columns[1].width == 0.25)
    #expect(s.focusedWindow == 1)
}

@Test func columnsDecodeTheOldSingleWindowFormat() throws {
    let old = #"{"window": 7, "width": 0.5}"#
    let c = try JSONDecoder().decode(Column.self, from: Data(old.utf8))
    #expect(c.windows == [7] && c.active == 0)
}
