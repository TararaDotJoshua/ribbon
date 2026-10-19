# Tab groups for Ribbon

Cross-app window tabs in the style of TrellisWM: any windows, from any apps,
share one column in the strip and switch from a strip of tabs above it.

## What TrellisWM does

From the [guide](https://trelliswm.app/docs) and
[how it works](https://trelliswm.app/how-it-works) pages, and the
[0.9.5 release notes](https://trelliswm.app/releases/TrellisWM-0.9.5.html):

- **Make a group:** drag a window over the *middle* of another, pause a moment,
  let go. The two become tabs of one window, even from different apps.
- **Switch:** click a tab.
- **Leave:** drag a tab out to make it its own window again; right-click a tab
  to close it or move it out.
- A whole tab group docks and moves like a single window.
- Background tabs are "tucked away" off screen. Their release notes mention
  fixing tucked windows that leaked onto a neighbouring display, and tab bars
  that flashed white while windows moved.
- It is a Pro feature with its own Settings pane (Tabs).

Paneru, our reference codebase, only handles macOS's *native* tabs (Finder,
Terminal), where macOS hides the background tabs itself. It has no cross-app
groups and draws no tab bar, so the tab bar and tucking are new work.

## How it fits Ribbon

A tab group is a **column holding several windows**, one of them showing.

- The column keeps one width, which grow, shrink, fill and the rest act on.
  Moving, paging and swapping move the group as a unit.
- The showing tab fills the column below a 28pt tab bar. The background tabs
  are tucked into the bottom-right corner of the screen, 5pt showing, like
  parked windows.
- Focus is per window. Focusing a background tab some other way (⌘-Tab, the
  Dock, a notification) makes it the showing tab.
- When a member closes or is minimised, it leaves the group. A group down to
  one window becomes a normal column and loses its bar.
- Groups are saved with the strip and restored on restart.

**Why tuck instead of stacking the tabs behind each other** (Paneru's approach
for native tabs): activating an app with ⌘-Tab brings *all* of its windows to
the front. A background tab stacked behind the showing one would jump in front
of it. Tucked windows are off screen, so that can't happen. Switching tabs is
two instant moves.

## Interactions

| How | What |
|---|---|
| Drag a window by its title bar over the middle of another, hold ~0.35s | A highlight says **Add as Tab**. Let go to group; move away to cancel |
| Click a tab | Show and focus that window |
| Drag a tab out of the bar | It becomes its own column, right of the group |
| Right-click a tab | **Move Out of Group**, **Close Window** |
| `⌃⌥ [` / `⌃⌥ ]` | Make the focused window a tab of the column to the left / right |
| `⌃⌥ \` | Move the focused tab out into its own column |
| `⌃⌥ ↑` / `⌃⌥ ↓` | Previous / next tab |

## Implementation

1. **Core model** (`RibbonCore/Strip.swift`, unit-tested). `Column` holds
   `windows` plus an `active` index, and decodes older saved state. New
   operations: `group(_:onto:)`, `joinNeighbour`, `ungroup`, `cycleTab`. The
   existing `remove` and `focus` become tab-aware. `frames` reserves the bar
   for grouped columns and tucks inactive tabs.
2. **Commands and keys**: `tab-into-left`, `tab-into-right`, `untab`,
   `prev-tab`, `next-tab`, all of which can also be sent with `Ribbon send`.
3. **Tab bar** (`TabBars.swift`): one borderless, non-activating panel per
   group, placed above the showing window. Clicking it never steals focus. It
   moves with every layout step (including glides) and is hidden while the
   group is parked off screen. It follows you to the active Space.
4. **Drag to tab**: a window that moves while the mouse button is down is being
   dragged. Ribbon polls the cursor; over the middle half of another window it
   waits out the delay, then shows the drop highlight. Releasing there groups
   the windows; anywhere else snaps back as today.
5. **Later:** reorder tabs by dragging within the bar; preview the result while
   holding a drag (TrellisWM 0.9.5); update titles live (`kAXTitleChanged`);
   use app colours on tabs; multi-display.

## Risks

- **Size limits:** tabs whose apps want different minimum widths. The column
  takes the widest of them.
- **Two title bars:** the tab bar sits on top of each app's own title bar.
  Fine for a first version; hiding the app's title bar isn't possible from
  outside the app.
- **Tucked windows across displays:** with a display below or to the right, a
  tucked window could appear there. TrellisWM hit exactly this. Ribbon tiles
  one display today; tuck toward a side with no neighbour when it gains
  multi-display support.
- **Electron and Chrome:** AX quirks. Ribbon already turns off
  AXEnhancedUserInterface while moving windows.
