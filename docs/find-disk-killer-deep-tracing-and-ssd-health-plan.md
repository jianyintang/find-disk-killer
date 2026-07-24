# FindDiskKiller Deep File Tracing and SSD Health Plan

> Status: design approved; baseline implementation complete; release and
> real-device gates remain mandatory<br>
> Created: July 23, 2026<br>
> Updated: July 24, 2026<br>
> Platform: macOS 14 or later, Apple silicon and Intel<br>
> Distribution: Developer ID signed and Apple-notarized website release<br>
> Constraint: no Endpoint Security entitlement, Endpoint Security system
> extension, or kernel extension<br>
> Priorities: responsive interaction, honest evidence, elevation on demand,
> and private paths by default

No special Apple entitlement does not mean no local approval. A bounded deep
trace requires macOS to approve the signed background helper. A protected path
may separately require Full Disk Access only after a real TCC coverage gap has
been confirmed. Both are local, revocable permissions and are not entitlements
requested from Apple.

This plan supersedes the Endpoint Security attribution, SSD health, and related
permission sections of the original product proposal.

## 1. Product Goal

FindDiskKiller already answers which applications consume disk, CPU, and
network resources. Deep inspection extends that answer:

1. Which files and directories does an application currently access?
2. During an explicit trace, how many read and write bytes did applications
   request for a selected file or directory?
3. Which child files and verified process sessions contributed most?
4. What host writes, wear, temperature, spare capacity, power history, and
   errors does a physical SSD report?

The product remains a diagnostic assistant rather than a file-auditing or
forensic system. It organizes process, path, time, and device-health evidence
into an understandable workflow.

### 1.1 Core Tasks

- Find the project, cache, log, or database touched while an AI agent keeps writing.
- Explain the directories involved in a sustained build, sync, or download.
- Compare requested read/write totals, latest five-second rates, and session peaks.
- Select a file or directory and see its most active child files and applications.
- Review cumulative host writes, wear, temperature, spare capacity, and media errors.
- Judge current activity against observed context without calling every build a fault.

### 1.2 Explicit Non-Promises

- Routine mode does not calculate exact per-directory bytes for a process.
- An FSEvents change is not attributed to a process.
- `fs_usage` requested bytes are not physical SSD writes.
- SIP, TCC, process lifetime, and system-format changes can create trace gaps.
- NVMe `Data Units Written` is host data, not NAND program bytes.
- Program/erase cycles are absent unless a model-specific, reviewed attribute exists.
- Remaining lifetime is not predicted without enough stable wear history.
- The app does not block file access, kill processes, clean files automatically,
  or record complete paths continuously in the background.

## 2. Capability Matrix

| Capability | Default | Approval | User-facing meaning |
| --- | --- | --- | --- |
| App total reads/writes and current/peak rates | Yes | None | Process I/O across all storage |
| Current open files and directories | When visible to the current user and TCC | None | Currently accessed; no per-directory bytes |
| Read-only, write-only, read/write open mode | For visible processes | None | Descriptor access mode, not proof of recent transfer |
| Recently changed directories | Yes on supported local volumes | None | macOS observed a change; process unknown |
| Selected target access trace | On demand | Signed helper approval | Successful system-call request bytes |
| Basic identity and SMART status | When exposed by macOS | Usually none | Device-reported state |
| NVMe host bytes, wear, temperature, and errors | Per field | Usually none | Only supported native fields |
| Extended SATA or bridge SMART | Future optional provider | Possibly | Only reviewed model-specific fields |

There is no global "enable attribution" switch. The UI exposes concrete tasks:

- View currently accessed locations.
- Trace this file or directory.
- View drive health.
- Disable and remove the trace component.

Unavailable states explain the current fact and the one actionable next step.
Internal phrases such as pending attribution or capability preparation never
appear in user-facing copy.

## 3. Evidence Sources and Accuracy

### 3.1 Process I/O

`proc_pid_rusage` supplies lifetime cumulative reads and writes. Sampling
deltas provide current, interval-average, and sampled-peak rates. These values
cover all storage touched by the process and are labeled application-wide I/O.

They differ from a physical device because of cache, memory mapping, APFS,
compression, swap, network file systems, and storage-layer merging.

### 3.2 Open Files

The app uses bounded `libproc` calls available in the macOS SDK but marked as a
private, changeable interface. This is permitted only in the Developer ID
website release and is guarded by supported-version fixtures:

1. `PROC_PIDLISTFDS` lists descriptors.
2. `PROC_PIDFDVNODEPATHINFO` resolves vnode descriptors.
3. `vnode_fdinfowithpath` supplies path, type, device identity, size, and flags.
4. Kernel `FREAD` and `FWRITE` bits determine read-only, write-only, or
   read/write mode after checking `O_EVTONLY`.

A snapshot proves that the process held the file at that moment. It does not
prove bytes moved during the interval. Copy says currently accessed or open for
writing, not definitely writing.

The scanner uses PID plus start identity, per-process descriptor limits, a
global syscall limit, and a 250 ms cross-call budget. A single kernel call
cannot be preempted safely, so the budget is checked between calls. Partial or
permission-denied coverage is labeled; it never becomes an empty result.

### 3.3 Recent Changes

FSEvents watches supported local writable volumes. Events may be coalesced at
directory level and do not include reliable process identity or byte counts.
The UI may state both facts independently:

- The application currently has a writable file open in this directory.
- macOS recently observed a change in this directory.

It must not merge them into "this application wrote this directory."

Each volume uses an independently managed stream and stable identity. The
implementation handles `MustScanSubDirs`, `UserDropped`, `KernelDropped`,
`EventIdsWrapped`, and `RootChanged`. A gap ends continuity and starts a new
baseline. Unmount and remount are also separate observation periods.

Recent-change evidence remains visible for five minutes after the last observed
change. Revisiting or rescanning a row cannot shorten that retention. The UI
states what an age value means, for example "last observed 28 seconds ago."

### 3.4 Bounded File Access Trace

The privileged helper supervises the system-provided executable using a fixed
argument array, never a shell:

```text
/usr/bin/fs_usage -w -f filesys -t <bounded-seconds>
```

The production helper accepts only its reviewed duration range and command
shape. The target path is not passed into the root process. The unprivileged app
normalizes paths, validates volume identity, and matches the selected target.

According to the macOS manual, `fs_usage` uses kernel tracing, requires root,
and may provide time, operation, descriptor, requested bytes, path, offset, and
thread/process text. `B=x` is the byte count requested by the call, not physical
storage traffic. Output varies by OS version and paths may be absent or
truncated.

Only successful calls with a verified process session and safely resolved path
enter target aggregation. Failed calls, unknown formats, unresolved identities,
truncated paths without safe recovery, rename/unlink ambiguity, and missing
volume identity become explicit coverage gaps.

Supported operations include reviewed forms of `read`, `pread`, `readv`,
`write`, `pwrite`, and `writev`. Any new core format fails closed until a fixture
defines it. The trailing numeric field in wide `fs_usage` output is a thread ID,
not automatically a PID. The root helper resolves thread ownership and freezes
PID plus process-start identity before transport.

### 3.5 Target Semantics

- Targets originate from the system file picker and must be absolute file URLs.
- Matching uses normalized path components and stable volume identity;
  `/foo` never matches `/foobar`.
- File and directory targets are distinguished explicitly.
- Case behavior follows the target volume.
- Symbolic links merge only when both selection and event resolution are verifiable.
- A hard link accessed through another tree is not guessed to be the selected path.
- Rename, unlink, descriptor-only I/O, truncation, or changed volume identity
  creates a coverage gap instead of a fabricated match.

### 3.6 Requested-Byte Semantics

The trace page consistently uses these labels:

- Requested reads.
- Requested writes.
- Latest five-second requested rate.
- Session peak requested rate.

Cache hits may not read the physical disk. APFS cache, compression, copy-on-write,
metadata, and delayed writeback can change physical writes. `mmap` and page
faults are not guaranteed to appear as path-resolved read/write calls. The page
therefore does not reconcile with device throughput or infer NAND writes.

### 3.7 Evidence Labels

| Label | Meaning | Directory bytes shown |
| --- | --- | --- |
| Currently accessed | The process currently holds the location | No |
| Recently changed | macOS observed a change; process not established | No |
| Observed in this trace | The session captured operation, path, and requested bytes | Yes, explicitly requested bytes |
| Unresolved | A request was captured but path or identity was unsafe | Total only; no target allocation |

The labels retain identical meaning in tables, charts, callouts, exports, and accessibility descriptions.

## 4. Architecture

```text
FindDiskKiller.app
  |-- MonitorStore                 CPU, disk, network, process samples
  |-- OpenFileSampler              bounded libproc snapshots
  |-- FileChangeWatcher            FSEvents directory changes
  |-- FileActivityCorrelator       independent evidence grouping
  |-- DiskHealthStore              native health capability model
  `-- FileAccessTraceStore         target session and aggregation
          |
          `-- XPC with mutual signing checks
                 |
                 `-- FindDiskKillerTraceHelper (root)
                       |-- fixed fs_usage supervisor
                       |-- bounded streaming and format gate
                       `-- child cleanup on every exit path
```

### 4.1 Trace Protocol

The shared protocol is narrow and versioned. It accepts a session token and
bounded duration, not a path or command. The helper returns bounded batches of
validated line payloads and frozen process identities.

Current hard limits include:

- Executable fixed to `/usr/bin/fs_usage`.
- Reviewed filesys arguments only.
- Duration constrained to the public trace contract.
- Maximum 32 KB per line.
- Maximum 4 MB buffered output.
- Maximum 2,048 lines per batch.
- Backpressure and dropped-line accounting.
- Timeout, explicit stop, App disconnect, SIGTERM, and unregister cleanup.

The app validates the helper's code-signing identity. The helper validates the
client audit token and signing requirement. Failure is fail-closed and cannot
fall back to `sudo`, `osascript`, a shell, or password capture.

### 4.2 Aggregation

The app consumes the stream without storing complete stdout. It maintains a
bounded ring and emits immutable snapshots to SwiftUI at 2-4 Hz.

Aggregation dimensions:

- Session requested-read and requested-write totals.
- Time-weighted latest five-second rates.
- One-second bucket peaks.
- Child file.
- Verified process session and grouped application.
- Coverage state, dropped count, unresolved count, and last event time.

Unknown or overflowed input marks the affected result partial or unsupported.
It does not silently discard evidence and continue showing exact-looking totals.

### 4.3 Session Lifecycle

1. The user selects a recent directory or target in File Activity.
2. The right-hand inspector updates without navigating away.
3. The user chooses Trace This Directory.
4. A dedicated trace workspace opens immediately with stable placeholder state.
5. If the helper is ready, collection starts automatically.
6. If approval is required, the workspace preserves intent and shows one inline step.
7. Returning after approval resumes the same pending start without a second click.
8. Stop, navigation away, window close, app quit, timeout, sleep handling, or
   disconnect terminates collection and reaps the child.
9. Leaving the trace surface clears session data. Re-entry starts a new session.

Permission progress never blocks sidebar or window navigation.

## 5. Interaction Design

### 5.1 File Activity Inspector

The File Activity section presents current locations and directories changed in
the last five minutes. The left list controls the right inspector; selection is
not a navigation action. The inspector includes:

- Friendly directory name and privacy-shortened path.
- Copy path and Reveal in Finder actions.
- Evidence labels with clear time language.
- A primary Trace This Directory command.
- An inline help button explaining the five-minute retention, observation age,
  and why a recent change is not process attribution.

Rows remain clickable while hover help is visible. Hover freezes reordering but
not hit testing. Tooltips are opaque, fit the window, and never overlap other text.

### 5.2 Trace Workspace

The first visible region contains target, state, elapsed time, coverage, totals,
latest five-second rates, and session peaks. Charts and lists follow without
nested decorative cards.

Two sortable and resizable tables show:

- **Most active files:** name, shortened path, requested reads, requested writes,
  latest activity, copy, and reveal actions.
- **Accessing applications:** verified icon, name, process session, requested
  reads/writes, latest rates, and coverage.

Paths use middle truncation but remain available through copy, details, and
VoiceOver. Copy has immediate confirmation. Empty state says "No read or write
requests have been observed for this target yet," not "No disk activity."

### 5.3 Charts

- Read and write lines use straight segments.
- Values are bucketed and do not cause layout shifts.
- Hover resolves the nearest data point and displays time plus both visible values.
- The callout remains inside the plot/window, uses an opaque surface, and does
  not intercept mouse input.
- Accessibility exposes the same interval through chart descriptors and a table.

### 5.4 Failure and Partial Coverage

Stable inline states cover helper unavailable, approval pending, denied,
unsupported output format, path coverage gap, dropped events, timeout, and
target removal. Each state has at most one primary next step. Repeated modal
alerts and notification spam are prohibited.

When exact target totals cannot be trusted, the UI shows unavailable or partial
coverage and explains why. It never converts missing data to zero.

## 6. Permission and Installation Experience

### 6.1 Default Mode

App launch, ordinary monitoring, open-file inspection, recent changes, and disk
health do not register the helper or request administrator approval.

The app may check helper status without registering it. No startup path opens
System Settings automatically.

### 6.2 Signed Helper

Registration uses `SMAppService` from the real signed app bundle. The SwiftPM
standalone executable is not a distribution artifact and cannot emulate this
lifecycle.

The system may require administrator confirmation and background-item approval.
The App reports registered, approval required, enabled, denied, failed, or not
installed accurately. It never calls the helper `sftool` and never loops a
permission request.

Settings exposes current status and Disable and Remove Trace Component. Helper
upgrade, app replacement, uninstall, crash, and force-quit are tested for orphan cleanup.

### 6.3 Full Disk Access

Full Disk Access is not presented preemptively. It appears only when real tests
show that TCC is the cause of missing coverage for the selected target. Copy
identifies the correct authorization subject and distinguishes it from helper
approval. Denial leaves routine monitoring functional.

## 7. SSD Health

### 7.1 Native Provider

The preferred source is structured output from bounded `diskutil info -plist`
and related whole-disk queries. Calls execute off the main thread with fixed
arguments, timeout, output-size limit, and schema validation.

Potential fields, when present and type-valid, include:

- Model, serial number, protocol, removable/internal state, and SMART status.
- `DATA_UNITS_READ_0/1` and `DATA_UNITS_WRITTEN_0/1`.
- `PERCENTAGE_USED`.
- `AVAILABLE_SPARE` and threshold.
- `TEMPERATURE`.
- `POWER_ON_HOURS_0/1` and `POWER_CYCLES_0/1`.
- `UNSAFE_SHUTDOWNS_0/1`.
- `MEDIA_ERRORS_0/1`.
- `NUM_ERROR_INFO_LOG_ENTRIES_0/1`.

Missing, malformed, or undocumented fields remain unavailable. They never become zero.

### 7.2 NVMe Detection

NVMe semantics require explicit evidence:

- Bus protocol contains NVMe or Apple Fabric; or
- Device-tree path contains `IONVMeController`, case-insensitively.

`PCI-Express` alone is not sufficient because it could describe non-NVMe
hardware. An external device with `IONVMeController` evidence may be described
to users as External NVMe (Thunderbolt/USB4) without fabricating a more specific
transport. Internal identifiers remain in hardware diagnostics.

### 7.3 Numeric Conversion

- NVMe counters are parsed as unsigned 128-bit values.
- One NVMe data unit equals 512,000 bytes.
- Temperature conversion occurs only after capability and plausible-range checks.
- Counter rollback, identity change, reset, and overflow break trend continuity.
- `PERCENTAGE_USED` is device-reported wear. Values above 100 are preserved in
  diagnostics but explained conservatively.

### 7.4 Health Page

The page leads with drive name, health summary, capacity, and connection. It
then uses an elegant unframed hierarchy:

1. **Endurance:** percentage used, available spare, cumulative host writes and reads.
2. **Current condition:** temperature and SMART status.
3. **Usage history:** power-on hours, power cycles, unsafe shutdowns.
4. **Errors:** media errors and error-information log entries.
5. **Hardware diagnostics:** expanded by default, including serial number when available.

Current Write on disk activity surfaces means the latest five-second average
write rate, not a whole-chart average.

Unsupported devices show the identity and a direct explanation: macOS did not
provide detailed health fields for this connection. The page does not imply
that installing another permission always fixes bridge hardware that does not
forward SMART.

### 7.5 Wear and Lifetime

The app can present device-reported wear, cumulative host writes, and observed
write trends. A remaining-time estimate requires all of the following:

1. A valid wear counter that has changed.
2. At least 30 valid calendar days of observation.
3. Stable device identity and monotonic counters without long gaps.
4. Change larger than the counter's reporting granularity.
5. A range with visible assumptions, never one deterministic failure date.

Otherwise the copy says that cumulative writes are available but remaining
life cannot yet be estimated. The app does not assign another model's TBW to an
Apple SSD with no public rating.

### 7.6 Program/Erase Cycles

Standard NVMe health logs do not normally expose actual NAND P/E cycles. The
field remains absent unless a vendor/model-specific SATA or extension attribute
has been reviewed. If displayed, it is labeled as device-reported and cites the
source attribute. It is not compared across vendors.

### 7.7 Optional smartctl Provider

`smartctl` is a future optional provider only if a measured device matrix shows
meaningful coverage beyond native macOS data. It cannot make a bridge forward
SMART when the enclosure does not support it.

Before implementation:

- Review smartmontools GPL-2.0-or-later distribution obligations.
- Keep the executable as a separate provider, not linked into proprietary code.
- Publish required license and corresponding-source access.
- Accept JSON output only with fixed command and device allowlists.
- Enforce timeout and output limits; never accept user-supplied `-d` or arbitrary options.
- Adapt vendor attributes by model before displaying their raw value.
- Reuse the helper security model only if root access is actually required.

Native NVMe devices must never depend on smartctl to read fields already exposed by `diskutil`.

## 8. Privacy and Retention

- Open-file snapshots and recent paths remain in memory.
- Raw trace output exists only in bounded helper/App transport memory.
- Trace data is cleared when the trace view is left or the session is cleared.
- User directory prefixes are shortened to `~` in ordinary display.
- Exports default to masking complete paths, usernames, command lines, and serial numbers.
- No paths, process activity, or health identity are uploaded.
- Clear This Session removes monitoring and trace state while retaining the
  identities required to keep currently mounted volumes stable.

## 9. Performance and Responsiveness

### 9.1 Routine Mode

- Open-file sampling adds less than 1% CPU at P95 on the idle reference Mac.
- Total app routine CPU remains below 2% at P95.
- A descriptor scan has a 250 ms cross-call budget and returns partial coverage on exhaustion.
- Process enumeration, path parsing, icon loading, and large-list sorting stay off the main thread.
- Navigation gives feedback within 100 ms; cached content or shape-matched skeletons appear immediately.

### 9.2 Trace Mode

- FindDiskKiller plus helper targets less than 8% additional CPU at P95 and less than 200 MB memory.
- Parsing and transport remain bounded.
- Summary values update at no more than 4 Hz; charts and detail tables at no more than 1 Hz.
- Backpressure first drops file-level detail while preserving aggregate coverage;
  if pressure remains unsafe, the session ends as partial.
- Stop acknowledges within 300 ms and reaps `fs_usage` within two seconds.
- Measurements include the child process and kernel tracing cost, not only the SwiftUI app.

## 10. Accessibility and Localization

- All ten languages use complete localized sentences and matching placeholders.
- Requested read, requested write, currently accessed, and recently changed are
  distinct concepts in every locale.
- VoiceOver row summaries include app, target, values, time window, and evidence.
- Charts provide equivalent tables.
- Keyboard users can select a directory, start/stop, change target, sort,
  resize columns, copy, and reveal in Finder.
- High contrast, reduced transparency, dark/light mode, large text, longest
  translations, and minimum windows are release-gate screenshots.
- Callouts use opaque surfaces and never overlap underlying text incoherently.

## 11. Test Gates

### 11.1 Open Files

- Controlled processes open fixed files read-only, write-only, read/write, and event-only.
- Verify kernel `FREAD`/`FWRITE` interpretation, unknown flags, FD reuse, held
  deleted file, rename, symbolic link, APFS Data path, PID reuse, `EPERM`, and `ESRCH`.
- Controlled current-user path recall is at least 99%; invisible paths are a coverage gap.
- Budget exhaustion is partial, not empty.

### 11.2 Recent Changes

- Create, modify, rename, delete, and directory batches identify the correct directory.
- Injected user/kernel drops create an immediate gap and new baseline.
- Tests never expect process identity or bytes from FSEvents.
- Hot plug, unmount/remount, read-only, unstable identity, and event storm are covered.

### 11.3 Trace Data

- Keep sanitized fixtures for every supported major macOS version.
- Cover supported reads/writes, error results, Unicode, spaces, long/truncated
  paths, unknown columns, malformed lines, FD reuse, process exit, and format changes.
- Controlled successful calls aggregate requested bytes within 1% of submitted bytes.
- Path coverage below 95% marks the result partial and suppresses a dominant-directory conclusion.
- Cover Codex, Claude, Xcode, Git, npm/pnpm, SQLite, large copies, rename/unlink,
  rapid child creation, file targets, directory targets, `/foo` vs `/foobar`,
  case-sensitive volumes, links, and identity changes.
- Consumer slowdown and event storms cannot create unbounded stdout or per-event SwiftUI rendering.

### 11.4 Trace Lifecycle and Security

- First approval, cancellation, waiting approval, denial, return from Settings,
  upgrade, unregister, app replacement, quit, force quit, timeout, sleep/wake,
  helper termination, and client disconnect.
- No orphan `fs_usage` process after any case.
- Fuzz and reject paths, commands, options, oversized lines, batches, durations,
  stale tokens, invalid clients, and unsupported protocol versions.
- Verify one approval path per explicit action, with no repeated modal loop.

### 11.5 SSD Data

- Deterministic unsigned-128 composition, reset, rollback, overflow, and unit conversion.
- `PERCENTAGE_USED` values 0, 1, 99, 100, and 255.
- Temperature capability and plausible ranges.
- Missing dictionary, partial fields, type mismatch, bridge without passthrough,
  device replacement, and weak identity never create false zero or inherited trend.
- Apple internal NVMe, third-party PCIe/Thunderbolt NVMe, USB NVMe bridge, SATA,
  and an unsupported external device.
- `PCI-Express` plus `IONVMeController` parses native NVMe fields; ordinary
  PCIe without that evidence does not.

### 11.6 User Experience

- 90% of target users find an application's top current directories within 30 seconds.
- 85% complete a one-minute trace and identify requested total, five-second rate, and peak.
- 85% correctly explain that requested writes differ from physical writes.
- 90% find host writes and percentage used without interpreting either as NAND cycles or failure date.
- Permission denial leaves routine monitoring usable and understandable.
- Navigation can interrupt startup or skeleton state, and hover never prevents a row click.

## 12. Implementation Status

As of July 24, 2026, code integration exists for the baseline below. Integration
does not replace the listed release gates.

| Area | Implemented | Remaining evidence |
| --- | --- | --- |
| Open locations | Bounded on-demand libproc snapshots, process-session identity, access modes, FD and time budgets | Supported-OS matrix, 24-hour performance, and broader system fixtures |
| Recent changes | Bounded FSEvents memory history for supported local writable volumes, topology refresh, gap rebuild | Event storms and real hot-plug matrix |
| Drive health | Whole-disk structured provider, optional fields, UInt128, instance validation, timeout/output limit, user-facing states | Broad real-device matrix and long-term trend identity |
| Trace core | Wide-line parser, operations, errno, format gate, target matching, 250 ms buckets, five-second rates, one-second peaks, file/process aggregation | Installed-helper real streams across supported macOS versions |
| Trace helper | Hardened Runtime bundle layout, LaunchDaemon metadata, mutual signing requirements, bounded XPC, fixed command, thread ownership, cleanup | Notarized clean-Mac approval, upgrade, removal, sleep, and force-kill evidence |
| Trace workspace | Application File Activity entry, immediate workspace, inline approval, totals, rates, peaks, charts, sortable/resizable tables, path actions | Real workload comprehension, performance, minimum-window, and accessibility gates |
| smartctl | Not implemented | Optional future license and device-value review |

## 13. Release Gates

| Gate | Owner | Pass condition | Status |
| --- | --- | --- | --- |
| DISTRIBUTION-0 | Release | Signed/notarized universal2 App, clean install, approval, upgrade, uninstall, orphan cleanup | Pending final artifact |
| TRACE-SECURITY | Security | XPC trust, fixed arguments, resource limits, lifecycle, path privacy | Pending installed-build evidence |
| TRACE-DATA | Platform/data | Request bytes, format handling, identity and target coverage | Pending real-OS matrix |
| TRACE-PERF | Performance | Routine and trace budgets plus 24-hour stability | Pending profile |
| SSD-DATA | Storage | Native conversion, optional fields, identity and device matrix | Pending full device matrix |
| UX-TASK | Product/UX | Task completion and comprehension thresholds | Pending user study |
| ACCESS | UX/QA | Keyboard, VoiceOver, contrast, text sizing, ten languages | Pending final UI matrix |
| DISTRIBUTION | Release | Developer ID, notarization, helper lifecycle, clean-Mac verification | Pending production release |

Gate order is `DISTRIBUTION-0 -> TRACE-SECURITY -> TRACE-DATA -> TRACE-PERF -> final UI release`.
Every gate records the exact build, commands, OS, architecture, hardware,
workload, reviewer, failures, and rollback conclusion. Unit tests and static
review cannot substitute for these records.

## 14. Review and Sign-off

The design requires independent platform/data, product/UX, and
delivery/security review. A reviewer must reject the build when any of the
following remains:

- An inference is displayed as a measurement.
- A permission or failure state offers no actionable next step.
- Permission denial disables routine monitoring.
- Hover, skeleton, refresh, or overlay prevents clicking or navigation.
- Missing SMART data appears as zero or healthy.
- Remaining SSD life is predicted without the required history.
- The helper can run an unapproved command or retain raw paths indefinitely.
- Any supported language, VoiceOver, or minimum window has overlapping content.

The approved design and baseline implementation do not automatically approve a
production build. Final sign-off requires the exact release PID/artifact,
real-device measurements, clean-Mac lifecycle results, and all gates above.
