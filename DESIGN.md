# FindDiskKiller Instrument UI

This document defines the visual language for the native macOS FindDiskKiller interface. It is intentionally written as implementation guidance: a future screen should be reproducible from these rules without inventing data or introducing a web-dashboard aesthetic.

## Product Character

FindDiskKiller is a quiet, professional diagnostic instrument. The interface is data-first, precise, and suitable for long sessions. It should feel native to macOS, with restrained physical depth rather than decorative effects.

- Prefer information density and stable alignment over oversized whitespace.
- Keep the current value and its state as the first visual focus; charts are secondary and icons are tertiary.
- Use native `NavigationSplitView`, `List`, `Table`, `Picker`, `Form`, `Toolbar`, and window behavior.
- Do not fabricate values, progress, health states, volumes, or application data for visual polish.
- Every user-visible string goes through `L10n`.

## Material

The app uses a layered instrument canvas and glass surfaces.

1. The canvas is a cool near-white mist in light appearance and a layered graphite/ink black in dark appearance.
2. A primary glass surface uses a translucent system material, a low-opacity neutral tint, and a subtle background blur.
3. The surface edge has a 0.5-1 px outline, a faint bright top/leading edge, and a darker trailing/bottom edge.
4. Add a short, soft contact shadow below the surface. Do not use large floating shadows.
5. Default panel radius is 8 px. Controls use 6 px. Icon bases use 6-7 px.
6. When Reduce Transparency is enabled, replace material with an opaque raised canvas color while preserving the same geometry and border.
7. During live window resizing, freeze expensive visual effects and remove shadows/animations to keep interaction responsive.

In code, prefer `InstrumentCanvas`, `GlassSurface`, `.glassSurface(...)`, and `InstrumentPageHeader` from `SharedComponents.swift`.

## Color Roles

Neutral colors must cover roughly 85-92% of the frame. Functional colors are reserved for current values, selection, direction, health, and real warnings.

| Role | Use | Token |
| --- | --- | --- |
| CPU / selection | CPU values, selected navigation, focus | `InstrumentDesign.ColorRole.cpu` |
| Disk read | Read throughput and read labels | `diskRead` |
| Disk write | Write throughput and write labels | `diskWrite` |
| Read / download | Low-saturation cyan direction | `read` |
| Write | Low-saturation amber direction | `write` |
| Network upload | Upload direction and metadata | `upload` |
| Memory | Memory and metadata accents | `memory` |
| Healthy | Monitoring and verified states | `healthy` |
| Warning | Only an actual threshold breach | `warning` |
| Cleanup | Safe cleanup actions | `cleanup` |

Never use rainbow or colored gradients. Neutral gradients are allowed only when they communicate glass thickness. Warning red must not appear in normal chart segments.

## Typography

Use the system font family. Keep letter spacing at zero and use `monospacedDigit()` for every live number.

- Page/diagnostic title: SF Pro Display semibold, 19-26 pt.
- Section title: SF Pro Display medium, 16-18 pt.
- Metric label: SF Pro Text medium, 11-12 pt, secondary color.
- Primary metric: SF Pro Display light/regular, 32-48 pt.
- Unit: SF Pro Text regular, 11-13 pt, visually subordinate on the same baseline.
- Table/path/time values: SF Mono, 11-13 pt.
- Axis and helper labels: SF Pro Text, 10-11 pt.

Use `DataValue` for value/unit baselines and `GlassMetricTile` for compact metric instrumentation. Values must not change layout width while updating.

## Page Composition

Secondary pages use the same vertical rhythm:

1. A compact `InstrumentPageHeader` with symbol, title, optional context, and trailing controls on one glass plane.
2. A scrollable content area on `InstrumentCanvas`.
3. Flat, stable rows inside a surface. Avoid a card inside another card unless the inner element is a genuinely framed tool or modal.
4. Keep the next information group partially visible when the window scrolls.

The main split sidebar is 220-280 pt wide. At narrow widths, keep the first three important metrics in one row by using `ViewThatFits`, smaller typography, and stable minimum dimensions before stacking lower-priority content.

## Screen Rules

### Applications

The process table is the primary instrument. Put range, search, and evidence controls in a glass toolbar surface. Keep columns aligned and compact. Selecting a row must update immediately; expensive detail work happens after that frame. The process list must not respond while another navigation destination is active.

### Settings

General and Data & Privacy remain native grouped forms, but the form background is transparent over `InstrumentCanvas`. Keep each logical group visually quiet and separated by material depth, not bright white cards. Toggles, sliders, menus, and confirmation actions retain native semantics.

### About

Use a calm identity surface for the app icon/version, a separate update instrument, and concise external-link rows. URLs use SF Mono and remain selectable. Link failures are shown inline without replacing the page.

### History Analysis

The page uses a glass header for period selection and export. The loaded and skeleton states share the same order and dimensions: report header, metric band, trend chart, insight, and application table. Coverage is shown as real coverage, never as fabricated completion.

### Disk Activity

Use a three-metric glass band for read, write, and mounted volumes. The physical throughput chart is a line chart with a pale same-color area fill and red only above the real warning threshold. Mounted volumes and hardware diagnostics are dense, scannable surfaces.

### Disk Health

Use a split inspector: a stable device list on the left and one selected device detail surface on the right. Health states must be expressed with icon, text, and color. Preserve previous data while a refresh is in progress and label stale results explicitly.

## Motion and Interaction

- Commit selection, focus, disclosure, and local loading feedback in the current or next frame.
- Live charts should translate left as a timeline, with the newest sample entering naturally at the right. Do not redraw the complete shape from scratch.
- Animate numeric changes with short, low-amplitude transitions. Use 0.25-0.40 s for sample transitions.
- Animate CPU energy segments, donut proportions, and network bars smoothly. Do not pulse or glow continuously.
- Respect Reduce Motion by disabling shape and value animations while preserving state changes.
- During live resize, freeze expensive effects and keep controls interactive.

## Accessibility

- Charts provide a VoiceOver summary that includes metric, range, latest value, and warning state.
- Do not communicate read/write, upload/download, normal, or warning using color alone; include text and symbols.
- Decorative skeletons are hidden from VoiceOver. Loading phase, errors, and cancellation actions remain readable.
- Icon-only controls have localized labels and tooltips.
- Increased Contrast strengthens borders and selection indicators without changing layout.
