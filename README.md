# WindowShift

Hold a modifier key, then **left-drag anywhere in a window to move it** and
**right-drag anywhere to resize it** — like alt-drag in Linux desktops.

Unlike Easy Move+Resize (which repositions windows through the Accessibility
API), WindowShift rewrites the intercepted mouse events in-flight so the
WindowServer runs a **genuine title-bar drag**. That means:

- macOS built-in edge tiling (drag to a screen edge) works.
- macOS "hold ⌥ while dragging to tile" works.
- Third-party snap-on-drag (Magnet, Rectangle, Loop, BetterTouchTool) works.
- Movement runs at native speed (no per-frame IPC), and the cursor never warps.

Right-drag resizes from the **corner nearest your click** (the window quadrant
you grab), via a genuine native resize session on the window's resize border.

With the modifier held, **double-left-click fills the screen** (the visible
frame; double-click the filled window again to restore its previous size) and
**double-right-click centers the window** (size unchanged). Double-click
speed follows your system setting.

Press **Esc during a drag to cancel it**: the session ends and the window
returns to its original frame (even undoing a snap that would have committed).
On haptic trackpads, a subtle alignment tick marks the moment the edge
handoff engages (tiling armed at the cursor).

## Build & run

Three equivalent ways to build:

```sh
make run          # Makefile: builds dist/WindowShift.app and opens it
./build.sh run    # plain shell script, same result (also: clean)
```

or open `WindowShift.xcodeproj` in Xcode 16+ (the target uses a synchronized
folder reference to `Sources/WindowShift`, so new source files are picked up
automatically) and run the WindowShift scheme.

Grant Accessibility permission when prompted (System Settings > Privacy &
Security > Accessibility). The grant survives rebuilds: the build signs with
your Apple Development certificate when one is in the keychain (set
`CODESIGN_IDENTITY` to pick a specific one), which yields a stable
certificate-anchored designated requirement; without any certificate it falls
back to an ad-hoc signature with a pinned identifier-based requirement, which
is likewise rebuild-stable. Not sandboxable (event taps + AX), so no App
Store.

## Configuration

All settings live in `defaults` domain `dev.nwf.WindowShift` and are also
exposed in the menu bar popup. The app observes the domain, so `defaults
write` changes apply immediately — no reload or relaunch needed.

```sh
# Modifier combo (default: ctrl,cmd). Any of: cmd, ctrl, opt, shift, fn.
# Also selectable from the menu bar: Trigger Modifiers submenu (the menu and
# this key are the same setting).
# Matching is exact: holding any modifier beyond the configured combo passes
# the click through untouched — with ctrl,cmd configured, a shift+ctrl+cmd
# drag reaches the app under the cursor as a normal shift-drag. A handy
# one-off bypass (disabledApps is the permanent one).
defaults write dev.nwf.WindowShift modifiers -string "ctrl,cmd"

# Drag mode (default: offset).
#   offset — the cursor stays where you grabbed; the window tracks it 1:1.
#            Approaching a tiling edge, the drag "hands off": over the last
#            stretch (4x edgeSnapProximity down to edgeSnapProximity) the
#            grab point drifts smoothly onto the cursor so tiling zones
#            preview/commit exactly at the mouse; it eases back if you pull
#            away. An edge only hands off while something actually has snap
#            zones there: the top and side edges follow the native tiling
#            switches in System Settings > Desktop & Dock, and every edge
#            (bottom included — native tiling has no bottom zones) hands off
#            while a snap-on-drag app (Magnet, Rectangle, Rectangle Pro,
#            BetterTouchTool, Loop) is running, since those apps read
#            locations off the same event stream. With nothing to snap to, a
#            drag never shifts the window at all. Only true outer screen
#            edges hand off (or clamp) — boundaries shared with an adjacent
#            display carry no zones and the drag crosses them freely.
#   warp   — the cursor jumps to the grab point (title bar / resize corner)
#            for the duration of the drag and back on release. Everything is
#            native-exact at all times, at the cost of the cursor jump.
defaults write dev.nwf.WindowShift dragMode -string "offset"

# Edge-handoff distance for offset mode, px from the top/left/right screen
# edges (0 disables the handoff — native tiling then reacts to the grab
# point, not the mouse)
defaults write dev.nwf.WindowShift edgeSnapProximity -float 30

# What happens to the collapsed handoff offset after the cursor leaves the
# edge band (also in the menu: Edge Handoff submenu). Matters for dragging
# windows into Mission Control's Spaces bar, which sits BELOW the edge band —
# if the offset is restored there, space drops track the (invisible) session
# pointer above the cursor instead of the cursor.
#   sticky          — once collapsed at any edge, stays collapsed all drag
#   top-sticky      — (default) stays collapsed only when engaged at the top
#                     edge (where Mission Control lives); eases back after
#                     left/right/bottom edges
#   mission-control — always eases back, but re-collapses whenever Mission
#                     Control is detected open (WindowManager overlay windows
#                     at layers 14/19 — no extra permissions needed)
defaults write dev.nwf.WindowShift handoffRelease -string "top-sticky"

# Distance below the window top where the synthetic title-bar grab lands (px)
defaults write dev.nwf.WindowShift titleBarInset -float 4

# Corner inset for the synthetic resize grab (larger for round-corner apps)
defaults write dev.nwf.WindowShift resizeInset -float 8

# Keep the grab point clear of the traffic-light buttons (px from window left)
defaults write dev.nwf.WindowShift trafficLightMargin -float 90

# Apps where WindowShift should do nothing
defaults write dev.nwf.WindowShift disabledApps -array "com.apple.finder"

# Menu bar icon (shown by default). Hide it from the menu (Settings > Hide
# Menu Bar Icon) or by ⌘-dragging the icon off the bar; WindowShift keeps
# running headless either way. To bring the icon back, open WindowShift
# again (Spotlight / Launchpad / Finder — relaunching the running app
# restores the icon) or set this key back to true.
defaults write dev.nwf.WindowShift showMenuBarIcon -bool true
```

Avoid `opt` as (part of) the modifier if the native "Hold ⌥ key while dragging
windows to tile" option is enabled — the OS reads the physical Option key
during any drag, so it stays reserved as the tiling accelerator.

Note: a modifier+click without any drag is swallowed (the app under the
cursor never sees the click) — that's inherent to grabbing the gesture.

## How it works

1. An active session-level `CGEventTap` watches left/right mouse
   down/dragged/up.
2. On modifier+mouseDown it swallows the click, finds the window under the
   cursor via `AXUIElementCopyElementAtPosition`, raises it, and computes a
   grab point: title bar (move) or nearest-corner resize border (resize).
   The title-bar spot targets the gap between the red and yellow traffic
   lights (read per-window from the AX close/minimize button frames — chrome
   in effectively every app, never overlapped by tabs or toolbars). Windows
   that don't expose button geometry fall back to an AX hit-test probe near
   the cursor that skips tabs/controls, then to the clamped cursor position.
3. The first drag event is mutated into a `leftMouseDown` at the grab point —
   the WindowServer hit-tests the drag region and starts a real drag/resize
   session.
4. Subsequent drag/up events pass through with a constant location offset
   (and right→left button rewrite for resize), so the window tracks the
   physical mouse 1:1 until release.

Technique studied from [AnyDrag](https://github.com/XueshiQiao/AnyDrag)
(GPL-3; mechanism studied, no code copied), with detection-side validation
against [Rectangle's SnappingManager](https://github.com/rxhanson/Rectangle)
and the WindowManager.framework tiling internals.
