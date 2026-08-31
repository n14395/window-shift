# WindowShift

**Move and resize macOS windows from anywhere — with real native tiling.**

Hold a modifier combo, then left-drag anywhere in a window to move it, or
right-drag to resize it — like alt-drag on Linux desktops. Unlike utilities
that reposition windows through the Accessibility API, WindowShift asks the
window server to run a **genuine drag session** on the window itself.
Everything that hooks into real drags just works:

- macOS built-in edge tiling (drag to a screen edge, macOS 15+)
- macOS "hold ⌥ while dragging to tile"
- Third-party snap-on-drag apps: Magnet, Rectangle, BetterTouchTool, Loop
- Native drag speed (no per-frame IPC), and the cursor never warps
- Works on any window — including ones whose title bar is crowded with tabs
  and toolbar controls, or parked off-screen entirely

<!-- TODO: demo GIF — drag from window body → native tile preview → Esc cancel -->

## Gestures

Default modifier combo: **⌃⌘** (configurable).

| Gesture | Action |
|---|---|
| modifier + left-drag | Move the window (with full tiling/snap integration) |
| modifier + right-drag | Resize from the corner nearest your click |
| modifier + double-left-click | Fill the screen's visible frame; repeat to restore the previous size |
| modifier + double-right-click | Center the window (size unchanged) |
| **Esc** during a drag | Cancel: the session ends and the window returns to its original frame — even undoing a snap that already committed |
| extra modifier on top of the combo | Bypass WindowShift for that click — it reaches the app untouched |

Double-click speed follows your system setting.

Optional, off by default: **magnetic window-to-window snapping** — while
moving, the dragged window's edges pull into abutment or alignment with
nearby windows' edges. Enable it from the menu (Settings → Magnetic Snap) or
via `magneticSnapDistance` below.

## Installation

Download the `.dmg` from [Releases](../../releases), drag WindowShift to
Applications, and launch it. Grant two permissions when prompted (both under
System Settings → Privacy & Security):

- **Accessibility** — to watch and rewrite the mouse events of the gesture.
- **Screen Recording** — nothing is ever captured or recorded; this is the
  permission macOS checks before one app may drive another app's windows,
  which is what the window-server drag call does. Without it windows still
  move, but via plain Accessibility repositioning — no native tiling and no
  Magnet/Rectangle snapping.

> **Gatekeeper note:** releases are signed with a development certificate and
> not notarized, so the first launch needs right-click → Open (twice on
> recent macOS), or `xattr -d com.apple.quarantine /Applications/WindowShift.app`.

Requires macOS 13+. Native edge-drag tiling itself is a macOS 15 (Sequoia)
feature; on older systems WindowShift still moves/resizes and integrates
with third-party snap apps.

### Building from source

No full Xcode required — the Swift CLI toolchain is enough:

```sh
./build.sh                 # build build/WindowShift.app
./build.sh --dmg           # ...and package it into build/WindowShift.dmg
./build.sh --sign          # ...Developer ID sign, notarize and staple
./build.sh --publish v1.2  # tag, push and cut a GitHub release from the .dmg
```

Flags combine. Then `open build/WindowShift.app`.

Builds sign with your Apple Development certificate when one is in the
keychain (`CODESIGN_IDENTITY` overrides the choice), falling back to an
ad-hoc signature with a pinned designated requirement. Either way the
signature is stable across rebuilds, so the Accessibility grant sticks.
WindowShift cannot be sandboxed (event taps + Accessibility), so it can
never ship through the Mac App Store.

## Settings

Everything is configurable from the menu bar popup, and every setting is a
key in the `dev.nwf.WindowShift` defaults domain — the app observes the
domain, so `defaults write` changes apply instantly, no relaunch needed.
The menu also shows a "Last drag:" diagnostics line explaining what the most
recent modifier-drag did (or why it was ignored).

| Key | Default | Meaning |
|---|---|---|
| `modifiers` | `ctrl,cmd` | Trigger combo; any of `cmd, ctrl, opt, shift, fn` |
| `magneticSnapDistance` | `0` (off) | Window-to-window magnetic snap distance in px |
| `resizeInset` | `8` | Resize grab inset from the corner, px (raise for big rounded corners) |
| `disabledApps` | `()` | Bundle IDs WindowShift ignores |
| `showMenuBarIcon` | `true` | Hide/show the menu bar icon (see below) |

```sh
# examples
defaults write dev.nwf.WindowShift modifiers -string "ctrl,opt,cmd"
defaults write dev.nwf.WindowShift magneticSnapDistance -float 8
defaults write dev.nwf.WindowShift disabledApps -array "com.apple.finder"
```

### Hiding the menu bar icon

Hide it from Settings → Hide Menu Bar Icon, or ⌘-drag the icon off the bar;
WindowShift keeps running headless. To bring it back, open WindowShift again
(Spotlight/Finder — relaunching the running app restores the icon) or set
`showMenuBarIcon` back to `true`.

### Good to know

- Avoid `opt` in the combo while the system's "Hold ⌥ key while dragging
  windows to tile" option is on — macOS reads the physical key during any
  drag, so it stays reserved as the tiling accelerator. The menu shows a
  warning when a selected combo conflicts with a system gesture.
- A modifier-click without a drag is swallowed (the app under the cursor
  never sees it) — inherent to grabbing the gesture; double-clicks are how
  the click-only actions are exposed.
- Magnetic snapping only considers windows adjacent on the other axis and
  never applies to resize drags. Neighbor positions are snapshotted when the
  drag starts.

## How it works

1. An active session-level `CGEventTap` watches left/right mouse
   down/dragged/up (a keyboard tap for Esc is armed only while a drag is in
   flight).
2. On modifier+mouseDown it swallows the click, finds the window under the
   cursor via the Accessibility API, notes its window-server ID, raises it,
   and parks a tiny invisible non-activating panel under the cursor.
3. The first drag event is rewritten into a `leftMouseDown` on that panel, so
   a mouse button is genuinely down and the app underneath never sees a click.
4. The second drag event calls the window server's
   `SLSDragWindowRelativeToMouse`, binding that live button press to a real
   server-side drag of the target window — named by ID, so nothing has to be
   clickable, on-screen, or free of controls. (This hand-over is what needs
   the Screen Recording grant.) The panel stays up until release: it owns the
   button press the session is bound to.
5. Subsequent drag/up events pass through (with a right-to-left button rewrite
   for resizes), and the window tracks the mouse 1:1 until release. Magnetic
   snapping is expressed as an adjustment to those event locations, because
   the drag follows the event stream rather than the hardware cursor.

Resize works the older way: the first right-drag is rewritten into a
`leftMouseDown` on the window's resize border at the nearest reachable corner,
which starts a native resize session. There is no window-server primitive for
interactive resize, and resize needs no tiling interop.

Because the drag session is genuine, everything downstream — native tiling,
Mission Control drops, Spaces edge-switching, Magnet/Rectangle — behaves
exactly as it does for a manual title-bar drag.

`SLSDragWindowRelativeToMouse` is private API, resolved at runtime rather than
linked. If a future macOS removes it — or the Screen Recording grant is
missing, in which case the call reports success and moves nothing — WindowShift
detects it empirically (a bound drag that doesn't move the window) and falls
back to plain Accessibility moves, saying so in the menu.

Event-rewriting technique studied from
[AnyDrag](https://github.com/XueshiQiao/AnyDrag) (GPL-3; mechanism studied, no
code copied), with detection-side validation against
[Rectangle's SnappingManager](https://github.com/rxhanson/Rectangle) and the
WindowManager.framework tiling internals. The window-server drag call was
found by probing SkyLight directly; see `window-move-mechanism-analysis-v1.md`.
