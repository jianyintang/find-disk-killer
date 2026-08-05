# Instrument Interface Design

This document defines the visual language for a native macOS instrument interface. It is a reusable design system: the rules describe appearance, composition, typography, state communication, and motion without depending on a particular product, domain, or data model.

## Design Intent

The interface should feel like a precise, quiet instrument rather than a marketing page or a web dashboard. It should support sustained attention and quick scanning through restrained contrast, stable alignment, and carefully controlled physical depth.

- Let hierarchy come from scale, spacing, and contrast before decoration.
- Prefer information density with generous grouping over oversized empty regions.
- Keep surfaces calm and legible in both light and dark appearances.
- Use color and motion to explain relationships or change, never as decoration without meaning.
- Preserve the same visual grammar when content, language, or window size changes.

## Canvas and Material

The interface is composed on a layered instrument canvas with translucent surfaces above it.

1. Use a cool, near-white mist for light appearance and a layered graphite/ink canvas for dark appearance.
2. Use translucent system material for primary surfaces, with a low-opacity neutral tint and subtle background blur.
3. Give each surface a 0.5-1 px outline, a faint bright top/leading edge, and a darker trailing/bottom edge.
4. Use a short, soft contact shadow below a raised surface. Avoid large floating shadows.
5. Use an 8 px radius for panels, 6 px for controls, and 6-7 px for icon bases.
6. When transparency is reduced, replace material with an opaque raised canvas color while preserving geometry, border, and hierarchy.
7. During live window resizing, freeze expensive blur and shadow effects and remove nonessential animation.

Depth should be legible from the edge treatment and tonal separation. Do not stack multiple decorative cards to create hierarchy; use whitespace, dividers, and material changes first.

## Color Roles

Neutral colors should cover roughly 85-92% of the frame. Accent colors are semantic tokens that can be assigned to any domain by the consuming screen.

| Role | Use | Token |
| --- | --- | --- |
| Primary accent | Current focus, primary values, or the active category | `accent.primary` |
| Secondary accent | A related comparison or supporting series | `accent.secondary` |
| Direction A | One side of a directional pair | `accent.directionA` |
| Direction B | The opposing side of a directional pair | `accent.directionB` |
| Positive | Verified or favorable state | `status.positive` |
| Caution | An actual condition requiring attention | `status.caution` |
| Destructive | Irreversible or dangerous action | `status.destructive` |
| Neutral | Context, inactive state, and supporting metadata | `neutral.*` |

Use one dominant accent and at most one supporting accent in a view. Avoid rainbow palettes and colored gradients. Neutral gradients are allowed only when they communicate material thickness. A caution or destructive color must not appear in ordinary chart segments.

Accent colors need a light and dark appearance variant, a high-contrast variant, and a disabled treatment. Text, symbols, borders, and fills should share the same semantic token instead of using unrelated near-duplicate colors.

## Typography

Use the system font family. Letter spacing is zero. Use monospaced digits for changing numeric values so updates do not move surrounding content.

- Display title: SF Pro Display semibold, 19-26 pt.
- Section title: SF Pro Display medium, 16-18 pt.
- Label: SF Pro Text medium, 11-12 pt, secondary color.
- Primary value: SF Pro Display light/regular, 32-48 pt.
- Unit: SF Pro Text regular, 11-13 pt, subordinate on the same baseline.
- Table and path values: SF Mono, 11-13 pt.
- Axis and helper labels: SF Pro Text, 10-11 pt.

Keep a clear baseline between values and units. Reserve display-scale type for page-level emphasis; compact panels, sidebars, tables, and tool surfaces use the smaller scales. Long labels wrap or truncate deliberately with enough width for the longest expected word; they must never overlap adjacent content.

## Layout and Composition

Use an 8 px base spacing unit. Related elements use 8, 12, or 16 px gaps; major groups use 24 or 32 px. Align titles, controls, values, and table columns to shared vertical guides.

1. Start a screen with a compact header containing an optional symbol, title, context, and trailing controls on one visual plane.
2. Place scrollable content on the instrument canvas, with stable top and side insets.
3. Use flat, stable rows inside a surface. A nested card is reserved for a genuinely framed tool, modal, or repeated item.
4. Let the next information group remain partially visible at the bottom edge when the window is scrolled, providing continuity without a separate banner.
5. Keep a split sidebar between 220-280 pt where navigation or inspection requires it. At narrow widths, use `ViewThatFits`-style alternatives and stack lower-priority groups only after the primary group has a stable minimum size.
6. Give fixed-format controls, tiles, grids, tables, and chart regions stable dimensions so labels and state changes cannot shift the layout.

### Common Surface Patterns

- **Header plane:** title hierarchy, context, and actions with one quiet material treatment.
- **Metric band:** two to four related values sharing a baseline and divider rhythm.
- **Inspector split:** a stable selection list beside one detail surface.
- **Dense table:** compact rows, aligned columns, and a restrained selection treatment.
- **Framed tool:** an isolated chart, editor, or confirmation surface that needs its own boundary.

These patterns are compositional options, not requirements for any particular screen.

## Data Visualization

Charts are part of the visual system and should remain readable without relying on decoration.

- Use a line for a changing quantity and a pale same-color area fill only when accumulated magnitude matters.
- Use a bar for comparison and a ring or segmented shape for a small number of proportions.
- Keep grid lines faint, axes quiet, and labels outside the data marks whenever possible.
- Use a consistent baseline, scale, and unit within a chart. Mark discontinuities with a visible gap or symbol rather than smoothing them away.
- Reserve the caution and destructive tokens for real state boundaries or annotations.
- Provide a text or symbol equivalent for every color-coded distinction.

## Motion and Physical Principles

Motion should explain continuity, focus, and causality. It must feel like a physical instrument settling into place, not a decorative animation layer.

- Use 0.25-0.40 s for ordinary value and sample transitions.
- Prefer ease-out for elements entering or expanding, ease-in for elements leaving, and ease-in-out for a state that transforms in place.
- Keep translation distances short: 4-12 px for local feedback and no more than one control height for a panel transition.
- Preserve object identity. A live series should translate along its timeline with the newest sample entering at the edge; do not redraw it as an unrelated shape.
- Animate opacity and position together for a surface transition. Avoid scale-popping controls and continuous pulsing or glowing.
- Use low-amplitude interpolation for changing values, with no overshoot unless the physical metaphor explicitly calls for it.
- Respect Reduce Motion by removing shape and value interpolation while preserving the final state and its hierarchy.
- During live resize, keep controls interactive and defer expensive visual effects until the new geometry settles.

## Interaction States

Every interactive element has distinct visual treatments for rest, hover, focus, pressed, selected, disabled, and unavailable states.

- Hover changes surface tint or border contrast subtly; it should not change layout.
- Focus uses a visible keyboard indicator with sufficient contrast and a stable inset.
- Pressed states reduce elevation or tint briefly to suggest contact.
- Selection changes both a visual token and a structural indicator such as a leading bar, icon, or fill; never use color alone.
- Disabled states reduce contrast and saturation while preserving readable labels and geometry.
- Loading and empty states keep the final layout's dimensions and hierarchy. Use quiet placeholders only for unknown content, and keep known state labels visible.

## Accessibility and Appearance Variants

- Maintain readable contrast for text, symbols, borders, and selected states in light, dark, increased-contrast, and reduced-transparency appearances.
- Pair every color distinction with text, shape, position, or symbol.
- Give icon-only controls a localized accessible name and a hover tooltip.
- Keep focus indicators visible when keyboard navigation is used.
- Hide purely decorative placeholders from assistive technologies while exposing the actual state and available action.
- Test narrow windows, large text, long localized labels, and both pointer and keyboard navigation without changing the design hierarchy.

## Implementation Notes

Represent the rules above as shared tokens and primitives so new screens inherit the same geometry, colors, typography, and motion. A screen may introduce domain-specific labels, icons, or data visualizations, but it should not introduce a new surface language without a deliberate design decision.
