# Instrument Interface Design System

This document defines a reusable visual system for native macOS instrument interfaces. It specifies design intent, concrete token values, composition rules, and motion behavior without depending on a particular product, domain, or data model.

## Design Intent

The interface should feel like a precise, quiet instrument rather than a marketing page or a web dashboard. It supports sustained attention and quick scanning through restrained contrast, stable alignment, and controlled physical depth.

- Let hierarchy come from scale, spacing, and contrast before decoration.
- Prefer compact, well-grouped information over oversized empty regions.
- Keep surfaces calm and legible in light, dark, increased-contrast, and reduced-transparency appearances.
- Use color and motion to explain relationships, focus, or change.
- Preserve the same visual grammar when content, language, or window size changes.

## Token Architecture

Tokens are the source of truth for visual decisions. They have three layers:

1. **Reference tokens** contain raw values, such as `color.blue.500` or `space.250`.
2. **Semantic tokens** describe purpose, such as `color.accent.primary` or `space.content.related`.
3. **Component tokens** combine semantic tokens for a specific reusable element, such as `surface.glass.radius`.

Use lowercase dot-separated names in the form `category.role.variant.state`. A global token must not contain a screen name, feature name, data source, or business concept. Component code consumes semantic or component tokens; raw values remain confined to the token definition.

All dimensions are in logical points (`pt`). Color values use the sRGB color space. Opacity is expressed as a number from `0` to `1`. Duration is expressed in seconds.

## Reference Tokens

### Neutral Color

Neutral tokens are adaptive because material depth must remain perceptually equivalent across appearances.

| Token | Light | Dark | Purpose |
| --- | --- | --- | --- |
| `color.neutral.canvas` | `#ECF0F2` | `#090B0D` | Base window canvas |
| `color.neutral.canvasRaised` | `#F6F8F9` | `#0F1315` | Opaque raised surface |
| `color.neutral.sidebarTint` | `#DBE2E6` at `0.58` | `#13171A` at `0.70` | Sidebar material tint |
| `color.neutral.white` | `#FFFFFF` | `#FFFFFF` | Edge light and material tint |
| `color.neutral.black` | `#000000` | `#000000` | Contact shadow and depth tint |

Text and separator colors use native macOS semantic colors so their contrast follows the active appearance:

| Token | macOS source |
| --- | --- |
| `color.text.primary` | `Color.primary` |
| `color.text.secondary` | `Color.secondary` |
| `color.text.tertiary` | `Color(nsColor: .tertiaryLabelColor)` |
| `color.separator` | `Color(nsColor: .separatorColor)` |
| `color.focus` | `Color(nsColor: .keyboardFocusIndicatorColor)` |

### Chromatic Color

The chromatic palette is deliberately muted. The values remain constant between light and dark appearances; usage opacity and surrounding neutrals provide adaptation.

| Token | sRGB | SwiftUI RGB | Intended character |
| --- | --- | --- | --- |
| `color.blue.500` | `#4D759E` | `(0.30, 0.46, 0.62)` | Precise, primary focus |
| `color.cyan.500` | `#4799A6` | `(0.28, 0.60, 0.65)` | Cool direction or flow |
| `color.amber.500` | `#BF782E` | `(0.75, 0.47, 0.18)` | Warm direction or caution |
| `color.graphite.500` | `#85919E` | `(0.52, 0.57, 0.62)` | Neutral comparison series |
| `color.green.500` | `#4F9E78` | `(0.31, 0.62, 0.47)` | Constructive action |
| `color.green.600` | `#4F9C59` | `(0.31, 0.61, 0.35)` | Positive or verified state |
| `color.violet.500` | `#8761A3` | `(0.53, 0.38, 0.64)` | Secondary quantitative series |
| `color.indigo.500` | `#7361A6` | `(0.45, 0.38, 0.65)` | Secondary directional series |
| `color.red.600` | `#BF3D38` | `(0.75, 0.24, 0.22)` | Destructive or critical state |
| `color.teal.500` | `#479687` | `(0.28, 0.59, 0.53)` | Constructive secondary action |

### Spacing

The spacing scale combines a 2 pt micro-grid with an 8 pt composition rhythm. Use the smallest token that still makes the relationship clear.

| Token | Value | Typical use |
| --- | ---: | --- |
| `space.0` | `0 pt` | Joined edges and divided rows |
| `space.050` | `2 pt` | Label-to-caption separation |
| `space.100` | `4 pt` | Tight inline grouping |
| `space.150` | `6 pt` | Compact control content |
| `space.200` | `8 pt` | Default inline gap |
| `space.250` | `10 pt` | Related icon and text |
| `space.300` | `12 pt` | Row and toolbar groups |
| `space.400` | `16 pt` | Compact surface inset |
| `space.450` | `18 pt` | Standard surface inset |
| `space.500` | `20 pt` | Page inset |
| `space.600` | `24 pt` | Section separation |
| `space.800` | `32 pt` | Major composition break |

Semantic spacing aliases:

| Token | Alias |
| --- | --- |
| `space.content.compact` | `space.150` |
| `space.content.related` | `space.250` |
| `space.surface.inset` | `space.450` |
| `space.page.inset` | `space.500` |
| `space.section.gap` | `space.600` |

### Radius and Stroke

| Token | Value | Purpose |
| --- | ---: | --- |
| `radius.small` | `5 pt` | Small tags and chart callouts |
| `radius.control` | `6 pt` | Buttons, fields, and segmented controls |
| `radius.icon` | `7 pt` | Icon bases |
| `radius.panel` | `8 pt` | Primary surfaces and repeated items |
| `stroke.hairline` | `0.6 pt` | Optical inner edge |
| `stroke.surface` | `0.75 pt` | Standard surface outline |
| `stroke.surface.increasedContrast` | `1 pt` | Increased-contrast outline |
| `stroke.chart` | `1.7 pt` | Primary chart series |

All rounded rectangles use continuous corners. Do not derive a new radius by scaling a component; choose the closest named token.

### Typography

Typography uses the system font families, zero letter spacing, and the platform's default line metrics. This retains native rendering while fixing the intended hierarchy.

| Token | Family | Size | Weight | Use |
| --- | --- | ---: | --- | --- |
| `type.display` | SF Pro Display | `26 pt` | Semibold | Highest page emphasis |
| `type.title` | SF Pro Display | `20 pt` | Semibold | Page title |
| `type.section` | SF Pro Display | `17 pt` | Medium | Section title |
| `type.body` | SF Pro Text | `13 pt` | Regular | Primary prose and controls |
| `type.label` | SF Pro Text | `12 pt` | Medium | Metric and field labels |
| `type.caption` | SF Pro Text | `11 pt` | Regular | Supporting metadata |
| `type.micro` | SF Pro Text | `10 pt` | Regular | Axes and dense helper labels |
| `type.value.large` | SF Pro Display | `48 pt` | Light | Singular primary value |
| `type.value.medium` | SF Pro Display | `36 pt` | Regular | Compact primary value |
| `type.unit` | SF Pro Text | `12 pt` | Regular | Unit on the value baseline |
| `type.data` | SF Mono | `12 pt` | Regular | Paths, times, identifiers, and tables |

Apply `monospacedDigit()` to any numeric text that changes in place. Values and units share the first text baseline. Display type is reserved for page-level emphasis; sidebars, tables, and compact panels use `type.section` or smaller.

### Opacity

| Token | Value | Purpose |
| --- | ---: | --- |
| `opacity.fill.subtle` | `0.10` | Quiet accent background |
| `opacity.fill.standard` | `0.12` | Selected or emphasized background |
| `opacity.fill.strong` | `0.22` | Light material tint |
| `opacity.border.standard` | `0.13` | Standard surface outline |
| `opacity.border.increasedContrast` | `0.40` | Increased-contrast outline |
| `opacity.disabled.content` | `0.45` | Disabled foreground content |
| `opacity.disabled.surface` | `0.60` | Disabled surface treatment |

Opacity tokens modify the color role; they never replace it. A disabled element uses both disabled opacity and a noninteractive cursor/behavior state.

### Motion

| Token | Duration | Curve | Purpose |
| --- | ---: | --- | --- |
| `motion.feedback` | `0.12 s` | `easeOut` | Hover and pressed feedback |
| `motion.state` | `0.20 s` | `easeInOut` | Selection and local state change |
| `motion.enter` | `0.28 s` | `easeOut` | Surface entering or expanding |
| `motion.sample` | `0.36 s` | `easeInOut` | Changing values and live samples |
| `motion.layout` | `0.40 s` | `easeInOut` | Small layout transformations |

Portable cubic-bezier definitions:

| Token | Control points |
| --- | --- |
| `curve.easeOut` | `(0.16, 1.00, 0.30, 1.00)` |
| `curve.easeIn` | `(0.70, 0.00, 0.84, 0.00)` |
| `curve.easeInOut` | `(0.65, 0.00, 0.35, 1.00)` |

For direct manipulation and reordering, use `motion.spring.settle`: mass `1`, stiffness `260`, damping `32.25`, initial velocity `0`. The damping value is approximately critical damping, `c = 2 * sqrt(k * m)`, so the element settles without decorative overshoot.

Reduce Motion resolves every duration token to `0 s` and replaces spring motion with an immediate state change. It does not remove the final position, opacity, or selection indication.

### Layout

| Token | Value | Purpose |
| --- | ---: | --- |
| `layout.sidebar.minWidth` | `220 pt` | Minimum usable sidebar |
| `layout.sidebar.idealWidth` | `250 pt` | Default sidebar |
| `layout.sidebar.maxWidth` | `280 pt` | Maximum sidebar before content gains priority |
| `layout.row.compactHeight` | `32 pt` | Dense table row |
| `layout.row.standardHeight` | `40 pt` | Standard list or inspector row |
| `layout.control.minimumHeight` | `28 pt` | Compact macOS control |
| `layout.iconButton.size` | `28 pt` | Stable square icon control |
| `layout.chart.minimumHeight` | `160 pt` | Compact readable chart region |

## Semantic Color Tokens

Semantic tokens bind the palette to visual meaning without binding it to business vocabulary.

| Token | Reference | Use |
| --- | --- | --- |
| `color.surface.canvas` | `color.neutral.canvas` | Window background |
| `color.surface.raised` | `color.neutral.canvasRaised` | Opaque fallback and raised plane |
| `color.surface.sidebar` | `color.neutral.sidebarTint` | Sidebar tint |
| `color.accent.primary` | `color.blue.500` | Current focus and primary quantitative series |
| `color.accent.secondary` | `color.violet.500` | Supporting comparison series |
| `color.direction.a` | `color.cyan.500` | First side of a directional pair |
| `color.direction.b` | `color.amber.500` | Opposing side of a directional pair |
| `color.data.neutral` | `color.graphite.500` | Neutral series or inactive comparison |
| `color.status.positive` | `color.green.600` | Positive or verified state |
| `color.status.caution` | `color.amber.500` | State requiring attention |
| `color.status.destructive` | `color.red.600` | Irreversible or critical state |
| `color.action.constructive` | `color.teal.500` | Constructive secondary action |

Neutral colors should cover roughly 85-92% of the frame. Use one dominant accent and at most one supporting accent in a view. Direction tokens are labels for a pair, not fixed business meanings; the consuming interface assigns their vocabulary consistently.

Avoid rainbow palettes and colored gradients. Neutral gradients are allowed only when they communicate material thickness. Caution and destructive colors do not appear in ordinary chart segments.

## Component Tokens

### Canvas

| Token | Light | Dark |
| --- | --- | --- |
| `canvas.background` | `color.surface.canvas` | `color.surface.canvas` |
| `canvas.material` | `ultraThinMaterial` at `0.34` | `ultraThinMaterial` at `0.46` |
| `canvas.highlight.start` | White at `0.34` | White at `0.028` |
| `canvas.shadow.end` | Black at `0.035` | Black at `0.16` |
| `canvas.gradient.axis` | Top-leading to bottom-trailing | Top-leading to bottom-trailing |

When transparency is reduced, omit the material and gradient layers while retaining `canvas.background`.

### Glass Surface

| Token | Value |
| --- | --- |
| `surface.glass.radius` | `radius.panel` |
| `surface.glass.inset` | `space.surface.inset` |
| `surface.glass.material` | `ultraThinMaterial` |
| `surface.glass.fallback` | `color.surface.raised` |
| `surface.glass.border.width` | `stroke.surface` |
| `surface.glass.border.color` | `color.text.primary` at `opacity.border.standard` |
| `surface.glass.innerBorder.width` | `0.5 pt` |
| `surface.glass.innerBorder.inset` | `1.25 pt` |

Surface layer recipe, from back to front:

1. Fill the continuous rounded rectangle with the material.
2. Apply a neutral tint: white at `0.22` in light appearance or black at `0.16` in dark appearance.
3. Apply a top-leading to bottom-trailing gradient: light `[white 0.30, clear, black 0.025]`; dark `[white 0.045, clear, black 0.10]`.
4. Draw the standard outline. Increased Contrast changes its opacity to `0.40` and width to `1 pt`.
5. Draw an optical edge with `stroke.hairline`: light `[white 0.72, white 0.025, black 0.10]`; dark `[white 0.20, white 0.025, black 0.34]`.
6. Inset `1.25 pt` and draw the `0.5 pt` inner highlight: white at `0.20` in light appearance or `0.035` in dark appearance.
7. Apply the elevation tokens below.

| Token | Light | Dark |
| --- | --- | --- |
| `elevation.surface.contact` | Black `0.10`, blur `7 pt`, y `3 pt` | Black `0.38`, blur `9 pt`, y `3 pt` |
| `elevation.surface.highlight` | White `0.30`, blur `1 pt`, y `-0.5 pt` | White `0.025`, blur `1 pt`, y `-0.5 pt` |

During live resize, remove material, gradients, and elevation; use `surface.glass.fallback` without changing padding, radius, or border geometry.

### Interactive Control

| Token | Value |
| --- | --- |
| `control.radius` | `radius.control` |
| `control.minimumHeight` | `layout.control.minimumHeight` |
| `control.inlineGap` | `space.150` |
| `control.hover.duration` | `motion.feedback` |
| `control.hover.fill` | Active semantic color at `0.10` |
| `control.selected.fill` | Active semantic color at `0.12` |
| `control.focus.stroke` | `color.focus`, `2 pt` outside the content edge |
| `control.disabled.contentOpacity` | `opacity.disabled.content` |

Hover, focus, pressed, selected, disabled, and unavailable states must not change the control's dimensions. Pressed state reduces visual elevation before changing fill; selection combines fill with a symbol, border, or positional indicator.

### Metric Band

| Token | Value |
| --- | --- |
| `metricBand.item.minWidth` | `144 pt` |
| `metricBand.gap` | `space.400` |
| `metricBand.divider` | `color.separator`, `stroke.hairline` |
| `metricBand.label` | `type.label`, `color.text.secondary` |
| `metricBand.value` | `type.value.medium`, `color.text.primary` |
| `metricBand.unit` | `type.unit`, `color.text.secondary` |

Two to four related values share a first-text baseline and equal-width tracks. The container reserves the widest expected value width so updates do not reflow adjacent items.

### Dense Row and Table

| Token | Value |
| --- | --- |
| `row.compact.height` | `layout.row.compactHeight` |
| `row.standard.height` | `layout.row.standardHeight` |
| `row.horizontalInset` | `space.300` |
| `row.columnGap` | `space.400` |
| `row.value` | `type.data` with monospaced digits |
| `row.separator` | `color.separator`, `stroke.hairline` |
| `row.selected.fill` | `color.accent.primary` at `0.12` |

Columns keep stable widths within a table. Selection changes in place and does not alter row height, padding, or column geometry.

### Chart

| Token | Value |
| --- | --- |
| `chart.stroke.width` | `stroke.chart` |
| `chart.area.opacity` | `0.10` |
| `chart.grid.stroke` | `color.separator` at `0.55` |
| `chart.axis.label` | `type.micro`, `color.text.tertiary` |
| `chart.transition` | `motion.sample` |
| `chart.minimumHeight` | `layout.chart.minimumHeight` |

Use a line for a changing quantity, bars for comparison, and a ring or segmented shape for a small number of proportions. Keep labels outside data marks where possible. A discontinuity is a visible gap or symbol, never a smoothed connection.

## Motion and Mathematical Behavior

Motion communicates continuity, focus, and causality. It should feel like a physical instrument settling into place rather than a decorative animation layer.

- Limit local feedback translation to `4-12 pt` and panel translation to one control height.
- Animate opacity and position together for a surface transition. Do not scale-pop controls.
- Keep a persistent object's identity across state changes; do not replace it with an unrelated shape.
- For a live horizontal series, translate existing samples by `dx = plotWidth / visibleIntervalCount` while the new sample enters at the trailing edge. Interpolate the translation with `motion.sample`.
- For numeric interpolation, use `v(t) = v0 + (v1 - v0) * E(t)`, where `E(t)` is the selected easing curve. Render with monospaced digits so interpolation cannot alter layout width.
- For proportional marks, interpolate normalized values before projecting them into pixels. Clamp only the rendered geometry, not the source value.
- Avoid continuous pulsing, glowing, or motion without a state transition.

## Composition Rules

1. Start a screen with a compact header containing an optional symbol, title, context, and trailing controls on one visual plane.
2. Place scrollable content on the canvas with `space.page.inset` at the sides.
3. Use flat, stable rows inside a surface. A nested card is reserved for a framed tool, modal, or repeated item.
4. Align titles, controls, values, and columns to shared vertical guides.
5. At narrow widths, preserve the primary group's minimum dimensions before stacking lower-priority groups.
6. Give boards, tiles, tables, chart regions, and icon controls stable dimensions so state and label changes cannot shift the layout.

Common compositions are a header plane, metric band, inspector split, dense table, and framed tool. They are reusable spatial patterns, not requirements for any specific screen.

## Accessibility and Appearance Variants

- Maintain readable contrast for text, symbols, borders, and selected states in all supported appearances.
- Pair every color distinction with text, shape, position, or symbol.
- Give icon-only controls an accessible name and a hover tooltip.
- Keep keyboard focus indicators visible and geometrically stable.
- Hide purely decorative placeholders from assistive technologies while exposing the actual state and available action.
- Long labels wrap or truncate deliberately; text never overlaps adjacent content.
- Test narrow windows, large text, long localized labels, and pointer and keyboard navigation without changing the visual hierarchy.

## Implementation Contract

Token definitions are versioned design decisions. A token value changes only when the system's visual language changes; a component-specific exception does not mutate a global token.

- Keep reference values in one namespace and expose semantic aliases to components.
- Use component tokens for shared surface recipes instead of repeating modifier chains.
- Do not place raw colors, spacing, radii, strokes, shadows, or motion durations in feature views.
- Add a new reference token only when no existing value expresses the intended relationship.
- Add a semantic token when an existing value needs a new stable purpose.
- Add a component token when two or more properties must remain visually coupled.
- Document appearance variants beside the base token rather than hiding them in implementation conditionals.
