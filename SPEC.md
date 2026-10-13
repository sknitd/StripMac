# SPEC: StripMac (recreating ChainYourMac 2.1, chainyourmac.com)

## Concept
StripMac is a scrolling tiling window manager. Every window is a column on one endless horizontal strip that runs past the screen edges. Nothing overlaps, and new windows never shrink the existing ones. You move around by keyboard or trackpad, and the strip scrolls just far enough to bring the focused column into view.

## Features (reference → StripMac status)
- Columns side by side, full height, with gaps that account for the Dock → done
- New windows open beside the focused one → done
- Strip follows focus, with a spring/eased animation → done (eased)
- Trackpad swipe moves the strip 1:1 and snaps to the nearest column → done (⌃⌥ + two-finger scroll, swallowed by an event tap; mouse wheel steps one column per notch)
- Preset widths 25/33/50/66/75%, nudge, full width, centre → done
- Centre modes: never, on overflow, always → done
- Strip minimap that fades out → done (app icon per column, focused/visible-area highlight, hover to hold, click to jump)
- Smart floating of fixed-size windows; per-app float rules → done
- Native fullscreen left alone → done
- Launch at login → done (SMAppService)
- Settings window that applies changes instantly; menu-bar item; guided start that teaches 5 shortcuts → done
- Only needs Accessibility; no telemetry → done
- Strip pinned to one chosen display; windows restored on-screen on stop/quit → done
- Stacks, tabbed columns, strips on several displays at once, per-Space strips, session restore, focus border/dimming, URL scheme/CLI → future work

## Shortcuts (⌃⌥ defaults, like the reference)
- Focus left/right: ⌃⌥←/→ and H/L
- Move: add ⇧
- Width presets: R; narrower/wider: - and =
- Full width: F; centre: C
- Equalize: 0; stop the window manager: Q
- Focus first/last: Home/End

## UI
- Menu-bar icon menu: Stop/Start Tiling, Re-tile, Settings…, Accessibility Setup…, Quit.
- Onboarding: tagline, Accessibility status (live), Grant / Open System Settings buttons, and a shortcut primer.
- Settings tabs:
  - General: gap, default width, presets, centre mode, gestures, minimap, login.
  - Rules: floating bundle IDs.
  - Shortcuts: the list of bindings.

## Architecture
- Swift (AppKit + SwiftUI), built with SwiftPM, targeting macOS 14+.
- AXUIElement for window discovery and frames.
- AXObserver notifications (plus NSWorkspace notifications) keep the strip in sync; a 1 s poll is the safety net. AX requests time out after 0.25 s.
- Carbon RegisterEventHotKey for global shortcuts.
- A CGEventTap on its own thread for ⌃⌥-scroll gestures.
