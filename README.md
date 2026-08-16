# WindowShift

**Move and resize macOS windows from anywhere — with real native tiling.**

Hold a modifier combo, then left-drag anywhere in a window to move it, or
right-drag to resize it — like alt-drag on Linux desktops. Unlike utilities
that reposition windows through the Accessibility API, WindowShift rewrites
the intercepted mouse events in flight so the WindowServer runs a **genuine
title-bar drag**. Everything that hooks into real drags just works:

- macOS built-in edge tiling (drag to a screen edge, macOS 15+)
- macOS "hold ⌥ while dragging to tile"
- Third-party snap-on-drag apps: Magnet, Rectangle, BetterTouchTool, Loop
- Native drag speed (no per-frame IPC), and the cursor never warps

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

On haptic trackpads, a subtle tick marks the moment edge handoff engages
(tiling armed at the cursor). Double-click speed follows your system setting.

Optional, off by default: **magnetic window-to-window snapping** — while
moving, the dragged window's edges pull into abutment or alignment with
nearby windows' edges. Enable it from the menu (Settings → Magnetic Snap) or
via `magneticSnapDistance` below.

## Installation

Download the `.dmg` from [Releases](../../releases), drag WindowShift to
Applications, and launch it. Grant **Accessibility** permission when prompted
(System Settings → Privacy & Security → Accessibility).

> **Gatekeeper note:** releases are signed with a development certificate and
> not notarized, so the first launch needs right-click → Open (twice on
> recent macOS), or `xattr -d com.apple.quarantine /Applications/WindowShift.app`.

Requires macOS 13+. Native edge-drag tiling itself is a macOS 15 (Sequoia)
feature; on older systems WindowShift still moves/resizes and integrates
with third-party snap apps.

### Building from source

No full Xcode required — the Swift CLI toolchain is enough:

```sh
make run          # build dist/WindowShift.app (+ versioned .dmg) and launch
./build.sh run    # shell-script equivalent (also: clean)
```

Or open `WindowShift.xcodeproj` in Xcode 16+ and run the WindowShift scheme
(the target uses a synchronized folder reference, so new source files are
picked up automatically).

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
| `dragMode` | `offset` | `offset` (cursor stays put) or `warp` (cursor jumps to the grab point) |
| `edgeSnapProximity` | `30` | Edge-handoff distance in px; `0` disables the handoff |
| `handoffRelease` | `top-sticky` | `sticky`, `top-sticky`, or `mission-control` (see below) |
| `magneticSnapDistance` | `0` (off) | Window-to-window magnetic snap distance in px |
| `titleBarInset` | `4` | Fallback grab depth below the window top, px |
| `resizeInset` | `8` | Resize grab inset from the corner, px (raise for big rounded corners) |
| `trafficLightMargin` | `90` | Keep-clear zone from the window's left edge for fallback grabs, px |
| `disabledApps` | `()` | Bundle IDs WindowShift ignores |
| `showMenuBarIcon` | `true` | Hide/show the menu bar icon (see below) |

```sh
# examples
defaults write dev.nwf.WindowShift modifiers -string "ctrl,opt,cmd"
defaults write dev.nwf.WindowShift magneticSnapDistance -float 8
defaults write dev.nwf.WindowShift disabledApps -array "com.apple.finder"
```

### Drag modes and edge handoff

Native tiling watches the drag session's pointer, which WindowShift keeps at
the window's title bar — away from your actual cursor. The two drag modes
resolve that differently:

- **`offset`** (default): the cursor stays where you grabbed and the window
  tracks it 1:1. Approaching a screen edge that carries tiling zones, the
  drag *hands off*: over the last stretch (4× `edgeSnapProximity` down to
  `edgeSnapProximity`) the grab point drifts smoothly onto the cursor, so
  zones preview and commit exactly at the mouse; it eases back if you pull
  away. An edge only hands off while something actually has zones there —
  the top and side edges follow the native tiling switches in System
  Settings → Desktop & Dock, and all edges (bottom included) hand off while
  a snap-on-drag app is running. Boundaries shared with an adjacent display
  never hand off; drags cross them freely. With nothing to snap to, a drag
  never shifts the window at all.
- **`warp`**: the cursor jumps to the grab point for the duration of the
  drag and back on release. Everything is native-exact at all times, at the
  cost of the visible cursor jump.

`handoffRelease` controls what happens to the collapsed handoff after the
cursor leaves the edge band — this matters when dragging a window into
Mission Control's Spaces bar, which sits *below* the band:

- `top-sticky` (default) — stays collapsed only after engaging the top edge
  (where Mission Control lives); eases back after the other edges
- `sticky` — once collapsed at any edge, stays collapsed for the whole drag
- `mission-control` — always eases back, but re-collapses whenever Mission
  Control is detected open (no extra permissions needed)

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
- Magnetic snapping only considers windows adjacent on the other axis,
  yields to tiling near screen edges, and never applies to resize drags.
  Neighbor positions are snapshotted when the drag starts.

## How it works

1. An active session-level `CGEventTap` watches left/right mouse
   down/dragged/up (a keyboard tap for Esc is armed only while a drag is in
   flight).
2. On modifier+mouseDown it swallows the click, finds the window under the
   cursor via the Accessibility API, raises it, and computes a grab point.
   For moves, it targets the gap between the red and yellow traffic-light
   buttons (read per-window from AX button geometry — chrome in effectively
   every app, never overlapped by tabs or toolbars), falling back to an AX
   hit-test probe that skips tabs/controls, then to the clamped cursor
   position. For resizes, it targets the window's resize border at the
   nearest corner.
3. The first drag event is mutated into a `leftMouseDown` at the grab
   point — the WindowServer hit-tests the drag region and starts a real
   drag/resize session.
4. Subsequent drag/up events pass through with a location offset (and a
   right→left button rewrite for resizes), so the window tracks the physical
   mouse 1:1 until release. Edge handoff, magnetic snapping, and the
   interior clamp are all expressed as adjustments to those event locations.

Because the drag session is genuine, everything downstream — native tiling,
Mission Control drops, Spaces edge-switching, Magnet/Rectangle — behaves
exactly as it does for a manual title-bar drag.

Technique studied from [AnyDrag](https://github.com/XueshiQiao/AnyDrag)
(GPL-3; mechanism studied, no code copied), with detection-side validation
against [Rectangle's SnappingManager](https://github.com/rxhanson/Rectangle)
and the WindowManager.framework tiling internals.
