#!/bin/sh
# Tab groups demo. Opens a few throwaway windows (two TextEdit notes, two
# Chrome pages in a temporary profile, a Finder window), runs the development
# build of Ribbon on just those apps, and makes the first two windows a tab
# group. Press Ctrl+C to end: the demo windows close and your installed Ribbon
# comes back.
#
# Needs Accessibility access for whatever runs it (the Claude app's terminal
# already has it), and an unlocked screen.
set -e
cd "$(dirname "$0")/.."
DEMO="${TMPDIR:-/tmp}/ribbon-demo"
mkdir -p "$DEMO"
INSTALLED_WAS_RUNNING=0
if pgrep -x Ribbon >/dev/null; then INSTALLED_WAS_RUNNING=1; pkill -x Ribbon; sleep 1.5; fi

printf 'Trip notes\n\nDay 1: Lisbon, tram 28 up to Alfama.\nDay 2: Sintra; Pena Palace opens at 9:30.\nDay 3: LX Factory, then Belém.\n\nPacking\n- adapter\n- walking shoes\n' > "$DEMO/Trip notes.txt"
printf 'Ribbon ideas\n\n- Tab groups (this demo)\n- Overview: zoom out to see the whole strip\n- Saved views on ctrl+alt+1-9\n- Reorder tabs by dragging in the bar\n' > "$DEMO/Ribbon ideas.txt"

# Don't let TextEdit reopen documents from earlier runs.
open -a TextEdit "$DEMO/Trip notes.txt" "$DEMO/Ribbon ideas.txt" --args -ApplePersistenceIgnoreState YES
open -na "Google Chrome" --args --user-data-dir="$DEMO/chrome" --no-first-run --no-default-browser-check \
  --new-window 'https://en.wikipedia.org/wiki/Tab_(interface)'
sleep 3
open -na "Google Chrome" --args --user-data-dir="$DEMO/chrome" --new-window 'https://en.wikipedia.org/wiki/Tiling_window_manager'
open /System/Applications
sleep 3

swift build --product Ribbon 2>&1 | tail -1
.build/debug/Ribbon --only TextEdit --only "Google Chrome" --only Finder &
RIBBON=$!

finish() {
  kill -TERM $RIBBON 2>/dev/null; sleep 1
  pkill -x TextEdit 2>/dev/null || true
  for p in $(pgrep -f "Google Chrom[e].app/Contents/MacOS/Google Chrome --user-data-dir=$DEMO"); do kill $p; done
  if [ $INSTALLED_WAS_RUNNING = 1 ]; then open -a "$HOME/Applications/Ribbon.app"; fi
  echo "Demo over."
  exit 0
}
trap finish INT TERM

sleep 3
for i in 1 2 3 4 5 6; do .build/debug/Ribbon send focus-left; sleep 0.15; done
.build/debug/Ribbon send tab-into-right
sleep 0.5
.build/debug/Ribbon send dump

cat <<'TXT'

Tab groups demo is running.
  Drag a window by its title bar over the middle of another, hold, let go: Add as Tab
  Click a tab to switch; drag a tab down out of the bar to pull it out
  Right-click a tab: Show, Move Out of Group, Close Window
  ctrl+alt+[ / ]   tab the focused window into its left / right neighbour
  ctrl+alt+\       move the focused tab out
  ctrl+alt+up/down previous / next tab
  ctrl+left/right, ctrl+shift+left/right   move along the strip as before
Press Ctrl+C here to end the demo.
TXT
wait $RIBBON
