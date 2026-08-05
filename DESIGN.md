# Instrument Interface Visual System

This document exists to reproduce the interface's visual character: material, color, edge treatment, depth, typography, icon rendering, and motion feel. It does not prescribe information architecture, page structure, content hierarchy, responsive layout, or product behavior.

## Visual Intent

The interface should feel like a precise, quiet native macOS instrument. Its character comes from restrained chroma, stable optical edges, shallow physical depth, crisp type, and motion that settles without spectacle.

- Let tonal contrast and material depth carry the hierarchy.
- Keep neutral color dominant and reserve chroma for visual meaning.
- Treat glass as a material response, not as a decorative card style.
- Preserve the same perceived depth in light, dark, inactive, and accessibility appearances.
- Use motion to express contact, continuity, and settling.

## Token Architecture

Tokens have three layers:

1. **Reference tokens** hold raw values, such as `color.blue.500` or `space.250`.
2. **Semantic tokens** describe visual purpose, such as `color.accent.primary`.
3. **Component tokens** combine semantic tokens into a reproducible treatment, such as `surface.glass.border.inner.width`.

Token names use lowercase dot-separated segments in the form `category.role.variant.state`. Every segment is lowercase; camel case is invalid. Global tokens never contain a screen, feature, data source, or business concept. All dimensions are logical points (`pt`), colors are sRGB, opacity ranges from `0` to `1`, and durations are seconds.

## Reference Tokens

### Neutral Color

| Token | Light | Dark | Purpose |
| --- | --- | --- | --- |
| `color.neutral.canvas` | `#ECF0F2` | `#090B0D` | Base window canvas |
| `color.neutral.canvas.raised` | `#F6F8F9` | `#0F1315` | Opaque raised surface |
| `color.neutral.chrome.tint` | `#DBE2E6` at `0.58` | `#13171A` at `0.70` | Optional window-chrome tint |
| `color.neutral.white` | `#FFFFFF` | `#FFFFFF` | Edge light and material tint |
| `color.neutral.black` | `#000000` | `#000000` | Contact shadow and depth tint |

Native semantic colors remain dynamic:

| Token | macOS source |
| --- | --- |
| `color.text.primary` | `Color.primary` |
| `color.text.secondary` | `Color.secondary` |
| `color.text.tertiary` | `Color(nsColor: .tertiaryLabelColor)` |
| `color.separator` | `Color(nsColor: .separatorColor)` |
| `color.control.background` | `Color(nsColor: .controlBackgroundColor)` |
| `color.focus` | `Color(nsColor: .keyboardFocusIndicatorColor)` |

### Chromatic Color

Chromatic values remain constant between light and dark appearances. Surrounding neutrals, fill opacity, and inactive-window treatment provide adaptation.

| Token | sRGB | SwiftUI RGB | Character |
| --- | --- | --- | --- |
| `color.blue.500` | `#4D759E` | `(0.30, 0.46, 0.62)` | Precise primary focus |
| `color.cyan.500` | `#4799A6` | `(0.28, 0.60, 0.65)` | Cool direction |
| `color.amber.500` | `#BF782E` | `(0.75, 0.47, 0.18)` | Warm direction or caution |
| `color.graphite.500` | `#85919E` | `(0.52, 0.57, 0.62)` | Neutral comparison |
| `color.green.500` | `#4F9E78` | `(0.31, 0.62, 0.47)` | Constructive action |
| `color.green.600` | `#4F9C59` | `(0.31, 0.61, 0.35)` | Positive state |
| `color.violet.500` | `#8761A3` | `(0.53, 0.38, 0.64)` | Secondary emphasis |
| `color.indigo.500` | `#7361A6` | `(0.45, 0.38, 0.65)` | Secondary direction |
| `color.red.600` | `#BF3D38` | `(0.75, 0.24, 0.22)` | Destructive or critical state |
| `color.teal.500` | `#479687` | `(0.28, 0.59, 0.53)` | Constructive secondary action |

Semantic aliases:

| Token | Reference |
| --- | --- |
| `color.surface.canvas` | `color.neutral.canvas` |
| `color.surface.raised` | `color.neutral.canvas.raised` |
| `color.accent.primary` | `color.blue.500` |
| `color.accent.secondary` | `color.violet.500` |
| `color.direction.a` | `color.cyan.500` |
| `color.direction.b` | `color.amber.500` |
| `color.status.positive` | `color.green.600` |
| `color.status.caution` | `color.amber.500` |
| `color.status.destructive` | `color.red.600` |

Neutral colors cover approximately 85-92% of a rendered surface. Use one dominant accent and at most one supporting accent in the same visual group. Avoid rainbow palettes and colored gradients. Neutral gradients exist only to communicate material thickness.

### Spacing and Shape

Spacing tokens define internal rhythm and optical construction, not page layout.

| Token | Value | Use |
| --- | ---: | --- |
| `space.050` | `2 pt` | Tight type separation |
| `space.100` | `4 pt` | Compact inline separation |
| `space.150` | `6 pt` | Control content gap |
| `space.200` | `8 pt` | Standard inline gap |
| `space.250` | `10 pt` | Icon-to-label gap |
| `space.300` | `12 pt` | Compact surface inset |
| `space.400` | `16 pt` | Standard surface inset |
| `space.450` | `18 pt` | Generous surface inset |

| Token | Value | Use |
| --- | ---: | --- |
| `radius.small` | `5 pt` | Small tags and callouts |
| `radius.control` | `6 pt` | Controls and icon buttons |
| `radius.icon` | `7 pt` | Standalone icon base |
| `radius.panel` | `8 pt` | Material surfaces |
| `stroke.hairline` | `0.6 pt` | Optical edge |
| `stroke.surface` | `0.75 pt` | Standard outline |
| `stroke.surface.contrast.increased` | `1 pt` | Increased-contrast outline |
| `stroke.focus` | `2 pt` | Keyboard focus ring |

All rounded rectangles use continuous corners. Choose a named radius; do not scale a radius with its component.

### Typography

Typography uses native system families, zero letter spacing, and platform-default line metrics.

| Token | Family | Size | Weight | Character |
| --- | --- | ---: | --- | --- |
| `type.display` | SF Pro Display | `26 pt` | Semibold | Highest visual emphasis |
| `type.title` | SF Pro Display | `20 pt` | Semibold | Primary title |
| `type.section` | SF Pro Display | `17 pt` | Medium | Compact heading |
| `type.body` | SF Pro Text | `13 pt` | Regular | Primary reading text |
| `type.label` | SF Pro Text | `12 pt` | Medium | Labels and controls |
| `type.caption` | SF Pro Text | `11 pt` | Regular | Supporting text |
| `type.micro` | SF Pro Text | `10 pt` | Regular | Dense helper text |
| `type.value.large` | SF Pro Display | `48 pt` | Light | Singular numeric emphasis |
| `type.value.medium` | SF Pro Display | `36 pt` | Regular | Compact numeric emphasis |
| `type.unit` | SF Pro Text | `12 pt` | Regular | Subordinate unit |
| `type.data` | SF Mono | `12 pt` | Regular | Paths, times, identifiers, and tabular values |

Use `monospacedDigit()` for numeric text that changes in place. A value and its unit share the first text baseline. SF Pro Display is reserved for emphasis; dense surfaces use SF Pro Text or SF Mono.

### Opacity

| Token | Value | Use |
| --- | ---: | --- |
| `opacity.fill.subtle` | `0.10` | Quiet accent fill |
| `opacity.fill.standard` | `0.12` | Selected fill |
| `opacity.border.standard` | `0.13` | Surface outline |
| `opacity.border.contrast.increased` | `0.40` | Increased-contrast outline |
| `opacity.window.inactive.accent` | `0.72` | Accent in an inactive window |
| `opacity.window.inactive.shadow` | `0.70` | Elevation in an inactive window |
| `opacity.disabled.control` | `0.46` | Disabled text control |
| `opacity.disabled.icon` | `0.42` | Disabled icon control |
| `opacity.unavailable` | `0.30` | Unavailable content |

### Motion

| Token | Duration | Curve | Use |
| --- | ---: | --- | --- |
| `motion.press` | `0.10 s` | `curve.ease.out` | Contact compression |
| `motion.hover` | `0.12 s` | `curve.ease.out` | Hover response |
| `motion.state` | `0.20 s` | `curve.ease.in.out` | Selection and focus change |
| `motion.enter` | `0.28 s` | `curve.ease.out` | Material entering or expanding |
| `motion.sample` | `0.36 s` | `curve.ease.in.out` | Continuous value transition |
| `motion.settle` | `0.40 s` | `curve.ease.in.out` | Small geometry transformation |

| Token | Cubic-bezier control points |
| --- | --- |
| `curve.ease.out` | `(0.16, 1.00, 0.30, 1.00)` |
| `curve.ease.in` | `(0.70, 0.00, 0.84, 0.00)` |
| `curve.ease.in.out` | `(0.65, 0.00, 0.35, 1.00)` |

`motion.spring.settle` uses mass `1`, stiffness `260`, damping `32.25`, and initial velocity `0`. The damping is approximately critical, `c = 2 * sqrt(k * m)`, producing a prompt settle without decorative overshoot.

Reduce Motion resolves all duration tokens to `0 s`, replaces the spring with an immediate state change, and preserves the final visual state.

## Window and Material Environment

Native material rendering depends on the window beneath it. Configure the window before evaluating any surface token.

| Token | Material enabled | Material disabled or Reduced Transparency |
| --- | --- | --- |
| `window.alpha` | `1` | `1` |
| `window.opaque` | `false` | `true` |
| `window.background` | Clear | `NSColor.windowBackgroundColor` |
| `window.content.full.size` | `true` | `true` |
| `window.title.visibility` | Hidden | Hidden |
| `window.titlebar.transparent` | `true` | `true` |
| `window.toolbar.style` | `NSWindow.ToolbarStyle.unifiedCompact` | `NSWindow.ToolbarStyle.unifiedCompact` |

The canvas extends beneath the titlebar and toolbar. Neither region receives an independent floating surface. The base immediately beneath every `ultraThinMaterial` layer is `color.surface.canvas`; never place material directly over a fully clear content hierarchy.

Canvas material uses SwiftUI `ultraThinMaterial` within the window. A glass surface uses `ultraThinMaterial` over the already-rendered canvas, so the two layers produce different depth despite sharing the same system material. Let system material follow the window's active state; do not force an always-active `NSVisualEffectView` state.

## Surface Recipes

### Canvas

| Token | Light | Dark |
| --- | --- | --- |
| `canvas.background` | `color.surface.canvas` | `color.surface.canvas` |
| `canvas.material.opacity` | `0.34` | `0.46` |
| `canvas.gradient.start` | White `0.34` | White `0.028` |
| `canvas.gradient.middle` | Clear | Clear |
| `canvas.gradient.end` | Black `0.035` | Black `0.16` |
| `canvas.gradient.axis` | Top-leading to bottom-trailing | Top-leading to bottom-trailing |

Layer order is base color, `ultraThinMaterial`, then neutral gradient. Reduced Transparency removes the material and gradient but retains the base color.

### Glass

| Token | Value |
| --- | --- |
| `surface.glass.radius` | `radius.panel` |
| `surface.glass.inset` | `space.450` |
| `surface.glass.material` | `ultraThinMaterial` |
| `surface.glass.fallback` | `color.surface.raised` |
| `surface.glass.border.width` | `stroke.surface` |
| `surface.glass.border.color` | `color.text.primary` at `opacity.border.standard` |
| `surface.glass.border.inner.width` | `0.5 pt` |
| `surface.glass.border.inner.inset` | `1.25 pt` |

Layer recipe, back to front:

1. Fill a continuous rounded rectangle with `surface.glass.material`.
2. Tint it white `0.22` in light appearance or black `0.16` in dark appearance.
3. Add a top-leading gradient: light `[white 0.30, clear, black 0.025]`; dark `[white 0.045, clear, black 0.10]`.
4. Draw the standard outline.
5. Draw the optical edge with `stroke.hairline`: light `[white 0.72, white 0.025, black 0.10]`; dark `[white 0.20, white 0.025, black 0.34]`.
6. Inset `1.25 pt` and draw a `0.5 pt` white highlight at `0.20` light or `0.035` dark.
7. Apply both elevation layers:

| Token | Light | Dark |
| --- | --- | --- |
| `elevation.glass.contact` | Black `0.10`, blur `7 pt`, y `3 pt` | Black `0.38`, blur `9 pt`, y `3 pt` |
| `elevation.glass.highlight` | White `0.30`, blur `1 pt`, y `-0.5 pt` | White `0.025`, blur `1 pt`, y `-0.5 pt` |

### Non-Glass Surfaces

| Surface | Fill | Border and edge | Elevation |
| --- | --- | --- | --- |
| `surface.flat` | Clear | Separator at `0.55`, `stroke.hairline` where separation is needed | None |
| `surface.opaque.raised` | `color.surface.raised` | Primary `0.10`, `stroke.surface`; top white edge `0.12` light or `0.04` dark | Light: black `0.06`, blur `4 pt`, y `1 pt`; dark: black `0.22`, blur `5 pt`, y `2 pt` |
| `surface.opaque.recessed` | Light: black `0.035`; dark: white `0.025`, over canvas | Inner top edge: black `0.08` light or black `0.34` dark; lower white edge `0.18` light or `0.04` dark | Inset only; no outer shadow |
| `surface.overlay.temporary` | `thickMaterial` with raised tint `0.18` | Primary `0.16`, `stroke.surface`; inner white `0.10`, `0.5 pt` | Light: black `0.16`, blur `12 pt`, y `5 pt`; dark: black `0.48`, blur `14 pt`, y `6 pt` |
| `surface.selection` | Active accent `0.12` | Active accent `0.28`, `stroke.surface` | None |

Use a non-glass surface whenever translucency does not communicate a distinct physical plane. Do not nest glass merely to increase contrast.

During live resize, every glass or temporary material resolves to its opaque equivalent and loses gradients and elevation. Geometry and borders remain unchanged.

## Control State Recipe

The base neutral control uses `radius.control`, a `28 pt` minimum height, horizontal inset `space.300`, `type.label`, and a top white highlight of `0.5 pt` at opacity `0.07`. Accent-filled and destructive variants substitute the active semantic color and use white foreground.

| State | Foreground | Fill | Border | Elevation | Transform | Motion |
| --- | --- | --- | --- | --- | --- | --- |
| `rest` | `color.text.primary` | `color.control.background` at `0.92` | `color.separator` at `0.90`, `0.75 pt` | Accent variants: active color `0.20`, blur `2 pt`, y `1 pt`; neutral: none | Scale `1` | None |
| `hover` | Unchanged | Neutral: primary `0.09`; accent: active color `0.92` | Unchanged | Unchanged | Scale `1` | `motion.hover` |
| `pressed` | Unchanged | Neutral: primary `0.13`; accent: active color `0.78` | Unchanged | Remove outer shadow | Text control scale `0.985`; icon control scale `0.96` | `motion.press` |
| `selected` | Active semantic color | Active color `0.12` | Active color `0.28`, `0.75 pt` | None | Scale `1` | `motion.state` |
| `focus` | State foreground | State fill | Add `color.focus`, `stroke.focus`, outside the content edge | State elevation | Scale `1` | `motion.state` |
| `disabled` | State foreground | State fill | State border | Remove outer shadow | Scale `1`; whole control opacity `0.46` | None |
| `unavailable` | `color.text.tertiary` | Clear | Separator `0.20`, `0.6 pt` | None | Scale `1`; whole control opacity `0.30` | None |

Hover is cleared when the pointer leaves or the window becomes inactive. Pressed never combines with hover elevation. Focus does not alter layout dimensions. Disabled means the control is visible but currently noninteractive; unavailable is visually quieter and has no material response.

## Icon Recipe

Use SF Symbols with monochrome rendering by default. Hierarchical rendering is allowed only when the secondary layer communicates the same semantic role. Multicolor rendering is not part of this visual system.

| Token | Value |
| --- | --- |
| `icon.weight` | Medium |
| `icon.size.micro` | `11 pt` |
| `icon.size.control` | `13 pt` |
| `icon.size.emphasis` | `22 pt` |
| `icon.foreground` | `color.text.primary` |
| `icon.foreground.secondary` | `color.text.secondary` |
| `icon.control.frame` | `30 pt` square |
| `icon.control.radius` | `radius.control` |
| `icon.control.fill.rest` | `color.control.background` at `0.78` |
| `icon.control.fill.hover` | Primary `0.10` |
| `icon.control.fill.pressed` | Primary `0.14` |
| `icon.control.border` | `color.separator` at `0.72`, `0.5 pt` |
| `icon.control.highlight` | Top white edge at `0.08`, `0.5 pt` |
| `icon.control.disabled` | Whole control opacity `opacity.disabled.icon` |

A standalone emphasis icon may use a base filled with its semantic color at `0.10`, `radius.icon`, and a `0.5 pt` border of the same color at `0.18`. It has no contact shadow. Icon geometry remains centered on the optical, not merely mathematical, bounds of the symbol.

## Appearance Matrix

Later columns override earlier base recipes. Geometry never changes between appearances.

| Element | Light | Dark | Increased Contrast | Reduced Transparency | Inactive Window |
| --- | --- | --- | --- | --- | --- |
| Canvas | Light canvas, material `0.34`, light gradient | Dark canvas, material `0.46`, dark gradient | Keep material; separator and edge opacities multiply by `1.5`, capped at `1` | Opaque canvas only; no material or gradient | System material follows inactive state; base color unchanged |
| Glass | Light glass recipe and light elevation | Dark glass recipe and dark elevation | Outline `0.40` at `1 pt`; inner highlight opacity doubles, capped at `0.40` | Replace material and tint with `surface.opaque.raised`; retain radius and standard outline; remove optical gradient | Accent content opacity `0.72`; shadow opacity multiplied by `0.70`; system material follows inactive state |
| Opaque surface | Light opaque recipe | Dark opaque recipe | Outline `0.30` at `1 pt` | Unchanged | Shadow opacity multiplied by `0.70` |
| Recessed surface | Light inset recipe | Dark inset recipe | Inner top edge opacity multiplied by `1.5` | Unchanged | Unchanged |
| Temporary overlay | Light overlay recipe | Dark overlay recipe | Outline `0.40` at `1 pt` | Replace `thickMaterial` with `color.surface.raised`; retain overlay shadow | Dismiss hover; shadow opacity multiplied by `0.70` |
| Control | Light native semantic colors | Dark native semantic colors | Border `1 pt`; focus ring `3 pt`; fill delta doubles | Use opaque native control background; no material tint | Clear hover and pressed; hide focus ring unless key-window focus remains |
| Accent | Base chromatic value | Base chromatic value | Base value; never increase saturation | Base value | Multiply rendered accent opacity by `0.72` |
| Icon base | Light icon recipe | Dark icon recipe | Border opacity `1`; focus ring `3 pt` | Opaque native control background | Clear hover; multiply accent foreground opacity by `0.72` |

## Motion and Mathematical Behavior

- Limit local feedback translation to `4-12 pt`. Do not use large travel to create importance.
- Animate opacity and position together for material entry. Do not scale-pop resting surfaces.
- Preserve persistent object identity across a state change.
- Interpolate numeric presentation as `v(t) = v0 + (v1 - v0) * E(t)`, where `E(t)` is the chosen curve. Monospaced digits prevent interpolation from changing width.
- Interpolate normalized proportions before projecting them into pixels. Clamp rendered geometry rather than source values.
- Avoid continuous pulsing, glowing, or motion without a state transition.

## Visual Reference Plates

The plates below are calibration aids, not layout examples. They contain no page structure or product content. Token tables remain normative; native macOS material should also be checked in a real active and inactive window because static SVG cannot reproduce compositor blur exactly.

![Light material reference](docs/assets/design/material-reference-light.svg)

![Dark material reference](docs/assets/design/material-reference-dark.svg)

![Control states and appearance variants](docs/assets/design/control-state-reference.svg)

## Accessibility

- Pair every color distinction with text, shape, position, or symbol.
- Give icon-only controls an accessible name and hover tooltip.
- Keep keyboard focus indicators visible and geometrically stable.
- Reduced Transparency and Reduce Motion preserve the final visual hierarchy.
- Long text never overlaps adjacent content; this is a rendering requirement, not a page-layout prescription.

## Token Governance

A token changes only when the visual language changes. A local exception does not mutate a global token.

- Keep reference values in one namespace and expose semantic aliases to components.
- Use component tokens for shared material recipes instead of repeating modifier chains.
- Keep raw colors, radii, strokes, shadows, opacities, and motion durations out of consuming views.
- Add a reference token only when no existing value expresses the intended visual relationship.
- Add a semantic token when an existing value needs a stable visual purpose.
- Add a component token when two or more properties must remain optically coupled.
- Document every appearance substitution beside its base token.
