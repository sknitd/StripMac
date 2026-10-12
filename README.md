# StripMac — a scrolling window manager for macOS 14+

Your windows sit on an endless horizontal strip. Each window is a full-height column. Nothing overlaps and nothing gets squeezed: opening another app makes the strip longer, and you scroll it. The model is the same as PaperWM and niri. This is an original, independent implementation.

## Features
- Full-height columns on an infinite horizontal strip. Columns that are off-screen are parked past the screen edges.
- New windows open right next to the focused one.
- The strip follows focus with an eased scroll animation. Focus changes from clicks and ⌘-Tab are tracked too.
- Preset widths (33/50/66/75/100% by default, editable), wider and narrower nudges, full width, centre, and equalize.
- Centre modes: never, when the strip overflows, or always.
- Trackpad: hold ⌃⌥ and scroll horizontally with two fingers. The strip moves 1:1 and then snaps to the nearest column. Three-finger swipe events are also handled when macOS delivers them.
- A strip minimap overlay that fades out after you navigate.
- Gaps and a layout that accounts for the Dock and menu bar (uses `visibleFrame`).
- Smart floating: fixed-size windows, minimized windows and fullscreen windows are left alone. A per-app float list lets you exclude apps by bundle ID.
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
- **Accessibility** (System Settings → Privacy & Security → Accessibility). This is the only permission StripMac needs. It is required to move and resize other apps' windows. The onboarding window opens the right pane for you and starts tiling as soon as you grant access.
- Global shortcuts use Carbon hot keys, so Input Monitoring is not required.
- If you rebuild the app, macOS may ask you to grant Accessibility again, because the ad-hoc signature changes.

## Known limits
- One strip on the main display. Windows of hidden or minimized apps are skipped.
- macOS keeps a sliver of an off-screen window visible at the screen edge.
