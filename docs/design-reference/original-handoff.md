# Handoff: Monitor Mirror — macOS Menu Bar Display Manager

## Overview
Monitor Mirror is a macOS-only menu bar (status bar) app for a Mac mini with three external displays. A small monitor-shaped icon sits in the menu bar; clicking it opens a minimal white popover showing all connected displays side by side. Clicking a display toggles it on/off (visually and functionally — the real app should enable/disable the display), and a quiet footer link opens macOS System Settings → Displays.

## About the Design Files
The file in this bundle (`Monitor Mirror.dc.html`) is a **design reference created in HTML** — an interactive prototype showing intended look and behavior, not production code. The task is to **recreate this design natively for macOS** (recommended: Swift + SwiftUI with `MenuBarExtra`, or AppKit `NSStatusItem` + `NSPopover`). The HTML mockup includes a fake macOS desktop and menu bar purely for context — only the menu bar **icon** and the **popover** are the product.

## Fidelity
**High-fidelity.** Colors, typography, spacing, and interactions are final. Recreate pixel-perfectly. Note: the prototype was designed at 1x CSS px; sizes below are points in SwiftUI terms.

## Aesthetic
Teenage Engineering–inspired: monospaced micro-typography, generous whitespace, a single warm orange accent (#FF4A00), no borders/boxes/dividers, everything communicated through color state and spacing.

## Views

### 1. Menu bar icon (NSStatusItem / MenuBarExtra)
- A monitor glyph: 16×11 rounded rect (radius 2.5, 1.5pt stroke, near-black #1B1B1A) with a 7×1.5 stand bar centered 4pt below.
- Inner screen area (inset 2pt, radius 1): filled **#FF4A00 when any display is on**, transparent when all are off. This is the at-a-glance state indicator.
- When the popover is open, the icon gets the standard highlighted background (in the mock: rgba(0,0,0,.09) rounded 6pt). Use the system's native status-item highlight on macOS.
- Template-image behavior: on macOS, the glyph stroke should adapt to menu bar appearance; keep the orange fill as-is (non-template tinted layer).

### 2. Popover
- Size: 324pt wide, content-hugging height (~200pt). Radius 18. Background pure #FFFFFF.
- Shadow: 0 24 60 rgba(0,0,0,.14) + 0 2 8 rgba(0,0,0,.06) (native NSPopover chrome is acceptable; prefer borderless white).
- Padding: 22pt top/left/right, 16pt bottom.

**Header row** (space-between, baseline-aligned):
- Left: "MONITOR MIRROR" — 11pt, weight 600, letter-spacing .16em, #1B1B1A.
- Right: active count "2/3" — 9pt, letter-spacing .12em, #8F8F8B.

**Display grid** — 3 equal columns, 14pt gap, 22pt below header. Each cell (tappable, radius 10, hover bg #F7F7F5, padding 6pt vertical):
- Mini monitor: 68×44 rounded rect (radius 6), plus an 18×2 stand bar (radius 1) 3pt below.
  - ON: fill #FF4A00 with a top sheen overlay (linear-gradient 180deg, rgba(255,255,255,.25) → transparent at 55%). Stand: #FF4A00.
  - OFF: fill #ECECEA, no sheen. Stand: #DCDCD8.
- Name (9pt, weight 600, letter-spacing .08em, centered, 9pt below monitor): #1B1B1A when on, #9A9A96 when off.
- Spec line (7.5pt, letter-spacing .08em, #9A9A96, 4pt below name): e.g. "5K · 60HZ".
- All state changes animate: background/color transitions .25s ease.

**Footer row** (space-between, 20pt below grid):
- Left: "MM–01" — 8pt, letter-spacing .14em, #AAAAA6 (decorative model label).
- Right: "DISPLAY SETTINGS ↗" — 8.5pt, letter-spacing .12em, #8F8F8B; hover color #FF4A00, transition .2s. Click opens System Settings → Displays.

## Interactions & Behavior
- Click status icon → toggle popover (native popover behavior: click-outside dismisses).
- Click a display cell → toggle that display on/off; animate colors .25s; update header count and status-icon fill.
- Hover a display cell → #F7F7F5 background, cursor pointer.
- "DISPLAY SETTINGS ↗" → open `x-apple.systempreferences:com.apple.Displays-Settings.extension` (or `NSWorkspace.shared.open` on the Displays pane). The prototype shows a toast instead.
- Sample data in mock: STUDIO (5K · 60HZ, on), DELL (4K · 60HZ, on), LG (QHD · 144HZ, off). Real app: enumerate via CoreGraphics (`CGGetOnlineDisplayList`) / `NSScreen`, derive short names + resolution class + refresh rate.

## State Management
- `displays: [{id, name, spec, on}]` — sourced from display APIs; `on` toggling requires a display enable/disable mechanism (e.g. CoreGraphics display configuration, or a helper like the `displayplacer`/private `CGSConfigureDisplayEnabled` approach — research current macOS support).
- `popoverOpen: Bool`.
- Derived: `anyOn` (icon fill), `activeCount` (header).

## Design Tokens
- Accent: #FF4A00 (alt options considered: #E03A00, #F2B300, #1B1B1A)
- Ink: #1B1B1A · Secondary text: #8F8F8B · Muted text: #9A9A96 · Faint label: #AAAAA6
- Off-monitor fill: #ECECEA · Off stand: #DCDCD8 · Hover fill: #F7F7F5 · Panel: #FFFFFF
- Font: IBM Plex Mono (400/500/600). On macOS, SF Mono is an acceptable native substitute; keep the wide letter-spacing.
- Radii: popover 18, cell 10, monitor 6. Transitions: .2–.25s ease.

## Assets
None — all visuals are drawn shapes. No images or icon files required.

## Files
- `Monitor Mirror.dc.html` — the interactive prototype (menu bar icon + popover + toggle behavior). Open in a browser to interact. Ignore the simulated desktop/menu-bar chrome around the popover.
