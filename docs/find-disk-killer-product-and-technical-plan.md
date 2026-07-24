# FindDiskKiller Product and Technical Plan

> Status: approved product baseline, updated July 24, 2026<br>
> Platform: macOS 14 or later, Apple silicon and Intel<br>
> Distribution: Developer ID signed and Apple-notarized website release<br>
> Product promise: help people see which applications are continuously using disk, CPU, or network resources, then present the strongest available volume and file evidence without inventing precision.

This document defines the durable product model. The current deep-tracing and
SSD implementation is specified in
[Deep File Tracing and SSD Health Plan](find-disk-killer-deep-tracing-and-ssd-health-plan.md),
which supersedes the older Endpoint Security proposal. The shipping product
does not require an Endpoint Security entitlement or kernel extension.

## 1. Product Definition

FindDiskKiller is a local macOS diagnostic tool for developers, creators,
operators, and advanced users. It helps answer three connected questions:

1. Is unusual disk activity happening now, and is it sustained?
2. Which physical device or mounted volume is under pressure?
3. Which applications, processes, and file locations provide useful evidence?

It is not an Activity Monitor replacement and does not compete by presenting
more unrelated system counters. Its value is an application-centered
investigation flow: notice pressure, identify the active application, and
understand disk I/O, CPU, network, files, and device health in one time context.

### 1.1 Core User Tasks

- Find the background application behind fan noise, stalls, heat, or battery drain.
- Distinguish a short spike from a sustained build, sync, download, index, or AI-agent workload.
- Identify the mounted volume backed by a busy physical device.
- Inspect an application's current files and recently changed locations.
- Start a bounded file or folder trace only when deeper evidence is needed.
- Review health fields reported by internal and external SSDs without reading raw `diskutil` output.

### 1.2 Product Principles

- **Conclusion before counters.** Lead with status, the main source of pressure,
  and the reason it matters. Keep specialist details available on demand.
- **Honest measurement.** Process I/O, device throughput, file-system changes,
  and requested file bytes are separate evidence sources and are never forced
  to reconcile.
- **Progressive permission.** Basic monitoring starts without administrator
  approval. A signed helper is requested only after an explicit trace action.
- **Quiet operation.** Do not send notifications or repeatedly open permission
  dialogs. Persistent conditions remain visible in the menu bar and app.
- **Local first.** Monitoring and analysis stay on the Mac. Complete paths are
  not uploaded or written to routine logs.
- **Native interaction.** Navigation, selection, sorting, detail windows,
  tooltips, loading states, and cancellation must respond immediately.
- **Native language quality.** Ten interface languages update without restart;
  complete sentences and locale-aware formats replace token-by-token translation.

## 2. Measurement Model

### 2.1 Evidence Sources

| Evidence | Source | What it answers | Important limitation |
| --- | --- | --- | --- |
| Physical-device reads and writes | Canonical IOKit block-storage counters | Which physical device is busy and at what rate | Shared APFS volumes do not own separate portions of the device total |
| Process reads and writes | `proc_pid_rusage` cumulative counters | Which visible process is producing I/O | The total covers all storage and is not physical NAND traffic |
| CPU | Host CPU ticks and process CPU time | Whole-machine load and application load | Whole-machine CPU is 0-100%; application CPU uses Activity Monitor semantics and may exceed 100% |
| Network | Physical interface counters and process network data | Download and upload activity | Coverage gaps remain unavailable rather than becoming zero |
| Open files | Bounded `libproc` snapshots | Which paths a process currently holds open and with which mode | An open writable file does not prove bytes were written during the sample |
| Recent changes | FSEvents | Which locations macOS observed changing | It does not provide reliable process identity or byte counts |
| On-demand access trace | Signed helper supervising `/usr/bin/fs_usage` | Successful read/write request bytes for a bounded session | Requested bytes differ from physical device I/O and can have coverage gaps |
| Drive health | Structured `diskutil -plist` data | Identity, SMART status, and available NVMe fields | Unsupported or missing fields remain unavailable |

### 2.2 Claims and Evidence

The interface must never claim that process A physically wrote an exact number
of bytes to device B. It may present these facts side by side:

- **Application I/O:** the process or application group's measured I/O total.
- **Device throughput:** the physical device's measured total.
- **File evidence:** paths that were open, changed, or observed in an explicit trace.

The product uses direct labels instead of abstract confidence scores:

- **Currently accessed:** the process held the location open at the sample time.
- **Recently changed:** macOS observed a change without identifying a process.
- **Observed in this trace:** a bounded trace captured a successful request and path.
- **Unresolved:** an event was captured but its path or process identity could not
  be resolved safely.

Missing visibility, counter resets, dropped events, unsupported formats, and
identity changes produce an explicit coverage state. They never produce a
plausible-looking zero.

### 2.3 Unsupported Production Approaches

- Do not use DTrace, kdebug, or arbitrary shell pipelines as a general monitor.
- Do not use FSEvents to calculate bytes or identify the writer.
- Do not ship a kernel extension.
- Do not introduce an Endpoint Security system extension unless a future,
  separately approved product plan requires it.
- Do not promise universal temperature, SMART, queue depth, latency, or busy
  percentage. Show only fields with verified semantics.
- Do not introduce `smartctl` merely to duplicate native NVMe fields already
  exposed by macOS.

## 3. Product Experience

### 3.1 Information Architecture

The main window uses a stable macOS sidebar and independent process-detail
windows:

1. **Overview:** current CPU, disk, and network pressure with leading applications.
2. **Applications:** sortable, resizable application rows and application-centered evidence.
3. **Disks:** physical devices, mounted-volume relationships, throughput, and health.
4. **Settings:** sampling, language, login item, privacy, trace component, support, and version.

Settings use the standard macOS Settings scene and are not duplicated as a
sidebar destination. The recommended main window is 1180 x 760 points with a
minimum of 920 x 620 points. The process-detail window targets 840 x 620 points.
Layouts must reflow before labels or values collide.

### 3.2 Menu Bar

The menu bar is a compact status surface, not a miniature dashboard:

- Optionally show current read, write, or combined throughput beside the icon.
- Present current rates, the busiest mounted volume, the leading application,
  and a 60-second microtrend.
- Offer clear actions to open FindDiskKiller and quit while stopping collection.
- Express elevated or failed state with shape, color, text, and VoiceOver, not color alone.
- Never open the main window or send a notification automatically.

### 3.3 Overview

- CPU appears first, followed by disk, network download, and network upload.
- Real-time values use the latest five seconds of actual sample time, not the
  average over the entire visible chart.
- Timelines offer one minute, 15 minutes, and one hour. Lines use straight
  segments, not smoothing.
- Chart hover selects the nearest sample and displays an opaque, compact,
  in-bounds callout with exact time and visible series values.
- Device rows lead with user-facing mounted-volume names such as `JianDisk`.
  BSD names and physical identifiers remain secondary details.
- Application rows expose native icons, name, current CPU, reads, writes,
  download, and upload. Every metric column supports ascending and descending
  sorting, and columns are resizable.
- Stable cached content appears immediately during navigation. A skeleton is
  used only when no compatible snapshot exists and must match final geometry.

### 3.4 Application Details

- Clicking a row gives immediate pressed and selection feedback, then opens a
  dedicated window that is never obscured by the sidebar.
- Multiple helper processes are grouped under their signed host application
  and can be expanded to individual sessions.
- The detail view shows CPU, disk, download, and upload charts in a two-column
  grid when space allows.
- File Activity shows current open locations and changes retained for five
  minutes after their last observation.
- Selecting a recently changed directory updates the right-hand inspector. It
  does not navigate away. A separate explicit action starts a trace workspace.
- Hover pauses visual reordering without preventing row clicks. The callout is
  non-interactive and cannot cover the clicked row's hit testing.

### 3.5 File Access Trace

A trace is entered from an application's File Activity workspace. The selected
file or directory opens a dedicated investigation surface and starts the
bounded session after any required system approval succeeds.

The first screen contains:

- Target name and privacy-masked path.
- Running, stopped, partial, or unavailable coverage state.
- Elapsed time and last observed event.
- Total requested reads and writes.
- Latest five-second requested read and write rates.
- Session peak rates from one-second buckets.
- Separate straight-line read and write charts.
- Sortable, resizable tables for active files and verified applications.
- Copy-path, reveal-in-Finder, stop, restart, change-target, and clear actions.

Leaving the trace surface automatically stops the high-cost trace and clears
the session. Re-entering starts a fresh session. Navigation remains usable
while approval or startup is pending.

### 3.6 Disks and Health

- Distinguish physical devices, APFS containers, and mounted volumes visually.
- Lead with friendly volume names, connection type, capacity, and mount point;
  keep BSD identifiers as secondary diagnostic information.
- Display current device reads and writes independently.
- Explain shared storage when several APFS volumes map to one physical store.
- Health uses a clear state summary, then identity, endurance, usage, power,
  temperature, and error groups. Hardware diagnostics are expanded by default.
- Display serial number only when macOS actually reports it. Mask it in exports
  and screenshots by default.
- NVMe health may include host reads/writes, percentage used, available spare,
  temperature, power-on hours, power cycles, unsafe shutdowns, media errors,
  and error-log count.
- Do not display NAND program/erase cycles unless a model-specific field has a
  reviewed meaning.

### 3.7 Permissions

Basic monitoring must never register the privileged trace component. An
explicit trace action may start the following state machine:

1. Explain why the component is needed in the trace workspace.
2. Ask macOS to register the signed helper once.
3. If macOS requires background-item approval, show one inline next step and
   open the correct System Settings pane.
4. Recheck on return and resume the pending trace without asking the user to
   click again.
5. Introduce Full Disk Access only when a verified TCC gap affects the selected
   target, and identify which executable requires the permission.

Administrator approval, background-item approval, and Full Disk Access are
separate states. No state may cause a loop of authorization dialogs. Users can
remove the helper from Settings.

### 3.8 Visual and Interaction Language

- Use system typography and semantic colors. Materials are limited to sidebar,
  toolbar, menu, and temporary overlays.
- Reads use teal with a solid line or circular marker. Writes use amber with a
  dashed line or square marker. Download and upload remain distinguishable by
  text, line style, and icon.
- Cards are reserved for repeated entities, dialogs, and genuine tools; do not
  nest cards or make every section float.
- Use tabular numerals and stable units within a visible time range.
- Respect Reduce Motion, Reduce Transparency, Increase Contrast, dark mode,
  keyboard navigation, VoiceOver, and large text.
- High-frequency collection never drives SwiftUI one event at a time. Visible
  snapshots are capped at 2-4 Hz depending on the surface.

### 3.9 Localization

The supported languages are Simplified Chinese, Traditional Chinese, English,
Japanese, Korean, German, French, Spanish, Brazilian Portuguese, and Russian.
Language changes update the main window, menu bar, settings, charts, and new
detail windows without restarting the app.

Localization gates require identical key and placeholder sets, locale-aware
date and number formatting, and overflow checks at minimum window sizes.

## 4. Technical Architecture

```text
FindDiskKiller.app
  |-- SwiftUI application and independent detail windows
  |-- MonitorStore and bounded live history
  |-- IOKit, libproc, FSEvents, network, and diskutil providers
  |-- FileAccessTraceStore and request aggregation
  `-- XPC client for an on-demand signed helper
          |
          `-- FindDiskKillerTraceHelper (root, optional)
                |-- fixed /usr/bin/fs_usage execution
                |-- bounded line and batch transport
                `-- stop, timeout, disconnect, and SIGTERM cleanup
```

The app is an Xcode-built bundle. SwiftPM remains the source of shared core
logic and tests but is not a substitute for the signed helper bundle layout.

### 4.1 Sampling and Data Flow

1. Sample cumulative physical-device and process counters on a monotonic clock.
2. Reject counter rollback, identity changes, sleep gaps, and device removal.
3. Aggregate current values over the latest five seconds of real sample time.
4. Preserve reads, writes, download, and upload as separate series.
5. Map devices to user-facing volumes using Disk Arbitration and IOMedia relationships.
6. Collect open files and recent changes with strict budgets and coverage states.
7. Deliver immutable UI snapshots at a bounded frequency.
8. Resolve icons, identities, paths, and sorting outside the high-frequency UI path.

### 4.2 Identity

- A process session uses PID plus start identity; PID alone is never durable.
- Application grouping prefers bundle identifier, signing identifier, and team identifier.
- A volume prefers volume UUID; BSD name and registry ID are session details.
- Device health uses a strong instance identity when available. Weak identities
  cannot inherit trends across replacement hardware.
- External PCIe devices are treated as NVMe only when explicit evidence such as
  `IONVMeController` exists; `PCI-Express` alone is insufficient.

### 4.3 Resource Budgets

All CPU values use Activity Monitor semantics, where one saturated logical core
is 100%.

| Scenario | Input | App plus helper CPU | Memory and loss |
| --- | --- | --- | --- |
| Idle monitoring | Fewer than 50 events/s for 30 min | average <1%, P95 <2% | stable, no unbounded growth |
| Normal monitoring | 500 events/s, 500 processes, 3 volumes | average <3%, P95 <6% | no dropped evidence |
| Active trace | representative build workload | P95 <8% additional | <200 MB for app plus helper |
| Event storm | bounded synthetic high rate | degrade before exceeding budget | bounded buffers and explicit dropped count |

Navigation feedback must appear within 100 ms. Stop feedback appears within
300 ms, and `fs_usage` is reaped within two seconds. App-level routine
monitoring must remain usable even when trace or health providers fail.

### 4.4 Security Boundary

- The helper is embedded in the signed app and registered only after explicit user action.
- Both XPC peers verify code-signing requirements and audit identity.
- The helper launches only `/usr/bin/fs_usage` with a fixed, validated argument shape.
- It does not launch a shell or accept arbitrary executables, environment,
  command-line options, or target paths.
- Session duration, line size, total buffer, batch count, and output rate are bounded.
- App disconnect, stop, timeout, termination, and unregister all terminate the child process.
- Raw trace lines remain in bounded memory and never enter routine logs.

### 4.5 Local Data

The current release keeps monitoring history in memory. Quitting the app or
using Clear This Session removes it. Preferences such as language and sampling
interval use the app's local preferences domain.

Complete paths are transient. Exports mask usernames, full paths, command
lines, and serial numbers by default. Deleting logical data does not claim to
make SSD blocks physically unrecoverable.

## 5. Anomaly Explanation

Sustained activity is a first-class state rather than a notification:

- Use current rate, duration, and volume before labeling activity notable.
- Explain likely classes such as builds, downloads, sync, cache, indexing, and
  AI-agent workspace scans without assuming a process is harmful.
- Update one stable in-app condition instead of producing repeated alerts.
- Never infer SSD wear directly from current process request bytes.
- A health error should recommend backing up important data without claiming a
  deterministic failure date.

## 6. Testing Strategy

### 6.1 Automated Coverage

- Counter deltas, five-second weighted rates, interval averages, and peaks.
- Activity Monitor CPU semantics on Apple silicon and Intel.
- Process session reuse, application grouping, icon fallback, and stable sorting.
- Network gaps and independent download/upload series.
- Volume identity, physical mapping, hot plug, sleep, and counter reset.
- Open-file flags, budgets, path normalization, and visibility failures.
- FSEvents retention, dropped-event gaps, and remount behavior.
- Trace parsing, requested bytes, errors, unsupported formats, backpressure,
  process identity, target boundaries, and lifecycle cleanup.
- Disk-health `UInt128` fields, units, temperature, missing fields, device
  replacement, and external NVMe detection.
- Localization key and placeholder parity for all ten languages.
- Hover state machines, detail-window leases, and clear-history behavior.

### 6.2 Controlled Scenarios

- Idle, sustained writes, burst reads, build, sync, download, SQLite, Git, and AI-agent workloads.
- Internal Apple NVMe, external Thunderbolt/USB4 NVMe, USB bridges, SATA, and unsupported SMART devices.
- APFS shared storage, encrypted volumes, removable devices, disk images, and network volumes.
- Permission allowed, denied, pending, revoked, helper upgrade, app quit, force
  quit, sleep/wake, and explicit unregister.
- Long names, Unicode and spaces, minimum window, ten languages, VoiceOver,
  keyboard-only use, reduced motion, reduced transparency, and increased contrast.

### 6.3 Data Quality Gates

- Missing or malformed fields remain unavailable.
- Process and device counters never get force-balanced.
- Unknown trace formats fail closed before byte aggregation.
- Trace path or identity coverage below the defined threshold suppresses precise summaries.
- No stale helper, XPC session, or `fs_usage` child remains after lifecycle tests.
- The UI never presents a loading or hover layer that blocks unrelated navigation or row clicks.

## 7. Delivery Gates

| Gate | Pass condition |
| --- | --- |
| Core data | Deterministic counter, identity, parser, and aggregation tests pass |
| Trace security | XPC trust, fixed command, limits, lifecycle, and path privacy pass |
| Trace data | Real supported-macOS fixtures meet identity and target coverage thresholds |
| Trace performance | Normal and high-rate workloads remain within bounded CPU and memory |
| SSD data | Native fields, optional values, external NVMe, and replacement identity pass |
| UX tasks | Target users can identify an active app, inspect files, and complete a trace |
| Accessibility | Keyboard, VoiceOver, contrast, text scaling, and ten languages pass |
| Distribution | Clean archive, Developer ID, Hardened Runtime, universal2, notarization, staple, Gatekeeper, clean-Mac install and uninstall pass |

A passing unit test suite does not replace a real-device, lifecycle, performance,
or distribution gate. Any unreliable metric or conclusion is removed rather
than defended with explanatory copy.

## 8. Release Scope

The website release includes:

- Current application CPU, disk I/O, download, and upload.
- Physical-device throughput with mounted-volume names.
- Application grouping, icons, sortable/resizable live tables, and independent details.
- Open-file locations and five-minute recent-change evidence.
- On-demand file access tracing through the signed helper.
- Available native NVMe/SMART health fields.
- Menu bar status, settings, login item, local clear action, and ten languages.
- Developer ID signing, notarization, privacy manifest, policies, and release verification.

The first release does not include cloud sync, accounts, telemetry, remote
control, process killing, automatic cleanup, universal SMART support, exact
process-to-device physical-byte attribution, or a deterministic SSD failure date.

## 9. Review Record

The product baseline has received platform/data, UX, and delivery/security
review. That approval covers the design and implemented baseline only. Release
approval still requires evidence from every gate above for the exact final
build. Reviewers must verify the final artifact and representative real-world
workloads rather than approving from static code inspection alone.
