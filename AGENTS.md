# Product Interaction and Loading-State Principles

## Prioritize UI Responsiveness

- After a user clicks, switches, expands, collapses, filters, or searches, commit the visible interaction state first. Selection, focus, disclosure indicators, or local loading feedback must appear in the current or next frame.
- Do not perform large-scale sorting, filtering, formatting, hierarchy resolution, file I/O, or database reads in an interaction callback before updating visible feedback.
- Cancel obsolete computations, coalesce rapid input, and move suitable work off the main thread. Work that must remain on the main thread must be split, cached, or deferred until after the first visual response.
- Lists and trees must use stable identities. Avoid repeated full-list scans and O(n^2) relationship lookups when expanding nodes; prefer indexes, caches, and lazy construction.
- When refreshing existing results in the background, keep the previous results interactive and show progress locally instead of blocking or rebuilding the entire page.
- Operations that cannot finish immediately must provide feedback that reflects their real state. Do not fabricate percentages, counts, or estimated durations to create a false sense of progress.

## Skeletons Must Match the Final Content Exactly

- A skeleton must precisely mirror the loaded information architecture, including the page header, toolbar, content groups, card or table count, primary dimensions, spacing, alignment, and responsive breakpoints.
- If the loaded first screen contains cards, the loading state must show the same number of cards in the same layout. Do not substitute unrelated rows, generic placeholder blocks, or a spinner-only state.
- Fixed skeleton regions must preserve stable dimensions to prevent layout shifts when data appears. Narrow-window stacking must use the same breakpoints and ordering as the loaded content.
- Skeletons represent only data that is not yet known. Do not fabricate titles, storage sizes, progress, or business states. Known scan phases, processed counts, and errors must be shown with normal text and progress components.
- Hide decorative skeleton shapes from assistive technologies. The actual loading state, current phase, and cancellation controls must remain readable by VoiceOver.

## Product Quality

- Do not treat barely functional behavior as complete. Workflows, state feedback, copy, keyboard interaction, accessibility, and visual hierarchy must meet the standard of a polished, restrained, professional macOS SaaS product.
- Do not create `backup/*` or any other backup branch unless the user explicitly requests one.
