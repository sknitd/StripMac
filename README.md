# StripMac — a scrolling window manager for macOS 14+

Your windows sit on an endless horizontal strip. Each window is a full-height column. Nothing overlaps and nothing gets squeezed: opening another app makes the strip longer, and you scroll it. The model is the same as PaperWM and niri. This is an original, independent implementation.

## Features
- Full-height columns on an infinite horizontal strip. Columns that are off-screen are parked past the outer edge of all displays.
- New windows open right next to the focused one. Windows that are minimised, hidden or on another Space come back to their old slot at their old width.
- Resize a column window by dragging its edge, and the column takes on the new width.
- The strip follows focus with an eased scroll animation. Focus changes from clicks and ⌘-Tab are tracked too.
- Preset widths (33/50/66/75/100% by default, editable), wider and narrower nudges, full width, centre, and equalize.
- Centre modes: never, when the strip overflows, or always.
- Trackpad: hold ⌃⌥ and scroll horizontally with two fingers. The strip moves 1:1 and then snaps to the nearest column. With a mouse wheel, each notch moves focus one column. These scroll events are kept from the app under the cursor.
- A strip minimap overlay that fades out after you navigate.
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
- Three-finger swipes are not supported; use ⌃⌥ with a two-finger scroll.
