/// Everything a key binding or `Ribbon send <command>` can ask for.
public enum Command: String, CaseIterable, Sendable {
    case focusLeft = "focus-left"
    case focusRight = "focus-right"
    case pageLeft = "page-left"
    case pageRight = "page-right"
    case moveLeft = "move-left"
    case moveRight = "move-right"
    case grow = "grow"                 // next wider preset
    case shrink = "shrink"             // next narrower preset
    case cycleWidth = "cycle-width"    // presets, wrapping around
    case widen = "widen"               // + widthStep
    case narrow = "narrow"             // - widthStep
    case toggleFill = "toggle-fill"
    case center = "center"
    case toggleFloat = "toggle-float"
    case tabIntoLeft = "tab-into-left"  // join the column to the left as a tab
    case tabIntoRight = "tab-into-right"
    case untab = "untab"                // move the tab out into its own column
    case prevTab = "prev-tab"
    case nextTab = "next-tab"
    case retile = "retile"
    case togglePause = "toggle-pause"
    case dump = "dump"
    case quit = "quit"
}
