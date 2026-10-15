# jwm — Jayakar Window Manager

An Emacs-style tiling window manager for macOS.

- **Buffers** are app windows. Windows that aren't displayed are parked offscreen (a 1px sliver stays at the bottom-right corner).
- **Panes** form an Emacs-style split tree. Each pane remembers the buffers it has shown and you can walk back/forward through them.
- **Tabs** are separate window configurations (split trees). The same buffer can appear in several tabs.
- New windows open in the selected pane, replacing what was there (it stays in that pane's history).
- Focusing a window that isn't displayed (Cmd-Tab, Dock click) shows it in the selected pane.
- Un-minimizing a window (or leaving native full screen) puts it back in the pane it came from.
- Apps' minimum window sizes are learned and respected: panes don't shrink below them, and a split that
  wouldn't fit is refused (like Emacs' "window too small for splitting").
- Each display has its own split tree and tabs. Commands act on the display with the selected pane.
  Moving a window to another display (drag, Raycast "Next Display", `⌘D m`) moves it to that display's
  layout; its old pane falls back through its history. Dropped against a side of the screen or onto a pane,
  it lands there.
- On start, jwm builds the layout from where windows are now: on each display, the windows you can see
  (at least half visible) become panes in a split tree that matches their positions and sizes, so they move
  as little as possible. Windows buried under others become hidden buffers. It does not restore the previous run's layout (menu bar → Reset Layout
  does the same thing at any time). Learned minimum window sizes are kept in
  `~/Library/Application Support/jwm/state.json`.
- Unplugging a display moves its layout to the main display as extra tabs (`⌘D ]` to see them); its
  windows stay hidden until then. Plugging it back in returns those tabs to it.
- jwm manages, per display, the desktop (Space) that display showed at start, and pauses while a display
  shows another one.
- If something else changes a tiled window's frame (mouse drag, Raycast/Rectangle, the app itself):
  - one edge moved per axis, and the split tree can express it → the split follows, and so do the other panes;
  - fills the screen → the pane is maximized (`⌘D f` restores the layout);
  - mostly covers another pane → the two windows swap;
  - against one side of the screen (Raycast left/right/top/bottom half, 2/3, …) → the pane moves to that
    side of the tab and the other panes shift to the opposite side;
  - anything else → the window snaps back.

## Keys

`⌘D` is a prefix, like Emacs `C-x`. Holding ⌘ for the second key works too (`⌘D ⌘3`).

| Keys | Action |
|---|---|
| `⌘D 3` | split selected pane side by side |
| `⌘D 2` | split selected pane top/bottom |
| `⌘D 0` | delete selected pane |
| `⌘D 1` | delete all other panes |
| `⌥Tab` / `⌥⇧Tab`, `⌘D o` | select next / previous pane, across all displays left to right (⌃Tab is left to browsers/editors) |
| `⌘D j` / `⌘D l` | back / forward in the pane's buffer history |
| `⌘D b` | buffer list (type to filter, ↑↓, Enter, Esc) |
| `⌘D f` | toggle full screen for the selected pane |
| `⌘D k` | close the selected buffer's window |
| `⌘D t` | new (empty) tab |
| `⌘D w` | close tab |
| `⌘D ]` / `⌘D [` | next / previous tab |
| `⌘D .` / `⌘D ,` | grow / shrink selected pane |
| `⌘D =` | balance panes |
| `⌘D m` | send the selected window to the next display |
| `⌘D n` | select the next display |
| `⌘D r` | re-scan windows and re-apply layout |
| *(M-x only)* | `reset-layout`, `quit-jwm` |
| `⌘D x` / `⌘D ?` | M-x: run any command by name (prefix search, Tab completes, `s-w-r` style partial completion) |
| `⌘D ⌘D` | send a real ⌘D to the app |
| `⌃V` / `⌥V` | Page Down / Page Up, like Emacs `C-v` / `M-v` (not in terminals or Emacs, which get the keys unchanged) |
| `⌘D Esc` / `⌘D g` | cancel |

## Install (Apple Silicon)

Download `jwm-<version>-arm64.app.zip` from [Releases](../../releases), unzip, move `jwm.app` to
`/Applications`, then:

```sh
xattr -dr com.apple.quarantine /Applications/jwm.app   # it's ad-hoc signed, not notarized
open /Applications/jwm.app
```

Grant Accessibility when prompted (System Settings → Privacy & Security → Accessibility), then open it
again. `jwm-<version>-arm64.tar.gz` is the bare binary, if you'd rather run it from a terminal.

## Running from source

```sh
make run       # build and run in the foreground; Ctrl-C quits and restores windows
make restore   # if jwm crashed, bring offscreen windows back
make app       # build jwm.app
make install   # build jwm.app and replace /Applications/jwm.app
make restart   # make install, then restart the running jwm (windows stay where they are)
make signing-cert  # once: local self-signed identity, so Accessibility survives rebuilds
```

jwm needs Accessibility permission. Run from a terminal, it uses the terminal's permission.

## Menu bar

The ▥ icon shows the tabs (`1 [2] 3`) and has Commands, Re-layout, Reset Layout and Quit. On a notched
MacBook it may be hidden behind the notch; ⌘-drag it somewhere visible and it stays there. Tab changes
are also announced at the bottom of the screen.

## Debugging

`JWM_DEBUG=1 make run` logs commands and placements. `pkill -USR1 jwm` prints the split tree and pane
histories; `pkill -USR2 jwm` renders jwm's own windows to `/tmp/jwm-snapshot-*.png`.

## Limitations (for now)

- One Space per display (it pauses while a display shows another Space).
- Floating windows (dialogs, non-resizable windows) aren't managed.
