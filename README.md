# StripMac — a scrolling window manager for macOS 14+

Your windows sit on an endless horizontal strip. Each window is a full-height column. Nothing overlaps and nothing gets squeezed: opening another app makes the strip longer, and you scroll it. The model is the same as PaperWM and niri. This is an original, independent implementation.

## Features
- Full-height columns on an infinite horizontal strip. Columns that are off-screen are parked past the outer edge of all displays.
- New windows open right next to the focused one. Windows that are minimised, hidden or on another Space come back to their old slot at their old width.
- Resize a column window by dragging its edge, and the column takes on the new width.
- The strip follows focus with an eased scroll animation. Focus changes from clicks and ⌘-Tab are tracked too.
- Preset widths (33/50/66/75/100% by default, editable), wider and narrower nudges, full width, centre, and equalize.
- Centre modes: never, when the strip overflows, or always.
- Modifier + scroll navigation: hold ⌃⌥ (Control-Option) and scroll to move along the strip.
  - Trackpad: two-finger horizontal (or vertical) scroll. The strip moves 1:1 and snaps to the nearest column when your fingers lift.
  - Magic Mouse: one-finger swipe on the surface, same 1:1 movement and snap.
  - Classic mouse wheel: each notch moves focus one column.
- Three- or four-finger swipe (trackpad, no modifier; three by default, pick whichever count macOS isn't using for Spaces): one swipe moves one window, like the native swipe between Spaces. Past either end of the strip it switches to the adjacent Space, so full-screen apps continue the strip (and swiping inside a full-screen app moves on, or back to the strip). Toggle in Settings → General.
  - While ⌃⌥ is held these scroll events are kept from the app under the cursor; without the modifier, scrolling works as normal. Toggle in Settings → General.
- A strip map overlay: one card per column with its app icon, the focused column highlighted and the visible area outlined. It fades out after you navigate; hover to keep it open.
  - Click a card to jump to that window. Hover a card for 2 s to see a live preview of the window (needs Screen Recording; without it the preview shows the icon and title).
  - Each card shows a live RAM gauge in its top-left corner: the app's share of physical RAM including its helper processes (as Activity Monitor groups them), green / orange / red at 8% and 20%. The caption shows the exact % and size.
  - Hover a card to show its × button. If the app has one window, × quits it. If it has more, a callout asks: **App** (quit it and close all its windows) or **This Window** (close only that one). Clicking anywhere else dismisses the callout. Apps may still ask to save.
  - Press and hold a card for 3 s: the cards wiggle like iPhone icons and you can drag them to reorder the strip. Click outside the cards or move the mouse off the map to finish.
- Gaps and a layout that accounts for the Dock and menu bar (uses `visibleFrame`).
- Smart floating: fixed-size windows, minimized windows and fullscreen windows are left alone. A per-app float list lets you exclude apps by bundle ID. Native window tabs share one column.
- Windows are put back on-screen when you stop tiling or quit, and when a window leaves the strip.
- A menu-bar item, a settings window (General, Rules, Shortcuts tabs), Accessibility onboarding, and launch at login.

## Default shortcuts (⌃⌥ = Control-Option)
| Action | Keys |
|---|---|
| Focus left / right | ⌃⌥← / ⌃⌥→ (or H / L) |
| Move window left / right | ⌃⌥⇧← / ⌃⌥⇧→ (or ⇧H / ⇧L) |
| Focus first / last | ⌃⌥Home / ⌃⌥End |
| Cycle preset width | ⌃⌥R |
| Narrower / wider | ⌃⌥- / ⌃⌥= |
| Full width | ⌃⌥F |
| Centre column | ⌃⌥C |
| Equalize widths | ⌃⌥0 |
| Start / stop tiling | ⌃⌥Q |
| Scroll the strip | hold ⌃⌥ + scroll (trackpad, Magic Mouse or wheel) |
| Next / previous window, then full-screen apps (trackpad) | three-finger swipe left / right (or four, in Settings) |

## Build
You need macOS 14+ and Xcode 15+ (or the Swift 5.9+ toolchain).
```bash
./build.sh            # produces build/StripMac.app and build/StripMac.zip
open build/StripMac.app
```
For development, run `swift build && .build/debug/StripMac`.

CI: GitHub Actions (`macos-14`) builds every push and uploads `StripMac.zip` as an artifact. Prebuilt zips are on the Releases page.

The app is ad-hoc signed. On first launch, right-click it, choose **Open**, then confirm (or run `xattr -dr com.apple.quarantine StripMac.app`).

## Permissions
- **Accessibility** (System Settings → Privacy & Security → Accessibility). This is the only permission StripMac needs. It is required to move and resize other apps' windows, and it also covers the event tap used for ⌃⌥-scroll. The onboarding window opens the right pane for you and starts tiling as soon as you grant access. If access is revoked while StripMac is running, tiling pauses and the onboarding window reopens.
- Global shortcuts use Carbon hot keys, so Input Monitoring is not required. If another app already owns a shortcut, Settings → Shortcuts marks it.
- If you rebuild the app, macOS may ask you to grant Accessibility again, because the ad-hoc signature changes.

## Known limits
- One strip, on the primary display by default (choose another in Settings → General → Strip display). Windows on other displays float; drag a column onto another display to take it out of the strip. A column that is only partly in view can extend onto an adjacent display.
- There is one strip, not one per Space. Windows on another Space leave the strip while you are away and return to their old slots when you come back.
- macOS keeps a sliver of an off-screen window visible at the edge of the outermost display.
- Windows are restored on-screen when tiling stops, on quit, on SIGTERM/SIGINT/SIGHUP, and (best effort) on a crash. After a force quit (SIGKILL) they stay parked until StripMac runs again, which picks them back up.
- Accessibility calls run on the main thread. Each one is capped at 0.25 s, and an app that times out is skipped for 3 s, so a hung app causes short hitches rather than a freeze.
- Native-tab detection relies on `_AXUIElementGetWindow`, a private but long-stable macOS call that other window managers also use.
- The trackpad swipe reads raw touches through the private MultitouchSupport framework (loaded at runtime, as Jitouch and MiddleClick do). The touches are observed, not swallowed: if macOS uses the same finger count for "Swipe between full-screen applications" (Trackpad → More Gestures), both react, so set macOS to the other count. Settings warns when they clash.
