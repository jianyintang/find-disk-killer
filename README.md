# FindDiskKiller

FindDiskKiller is a native macOS app for finding applications that generate
unexpected disk activity. It brings disk I/O, CPU, network traffic, open file
locations, recent file-system changes, and physical-drive health into one
application-centered workspace.

The app is designed for developers and other Mac users who need to answer
questions such as:

- Which application is writing to disk right now?
- Is the activity sustained or only a short spike?
- Which mounted drive is busy?
- Which locations does an application currently have open?
- Was a related location modified during the last five minutes?

## Highlights

- Five-second rolling CPU, disk, network, and per-device rates.
- Application grouping with native icons and audited brand fallbacks.
- Sortable, resizable application columns with stable live updates.
- Separate network download and upload measurements.
- One-minute, 15-minute, and one-hour timelines with interactive values.
- Independent process detail windows for side-by-side investigation.
- Current open-file locations plus file-system changes retained for five
  minutes after they are observed.
- Mounted-volume names mapped to physical-device throughput.
- Physical-drive health and available NVMe/SMART evidence from `diskutil`.
- Ten interface languages.
- Menu bar status for lightweight monitoring.

## Measurement Model

FindDiskKiller keeps evidence from different macOS data sources separate so a
precise-looking number never implies more certainty than the system provides.

| View | Source and meaning |
| --- | --- |
| Application disk I/O | Per-process counters from `proc_pid_rusage`, grouped by application. Current rates are time-weighted over the latest five seconds and cover all disks combined. |
| Device throughput | Public IOKit counters for physical storage devices, shown through user-facing mounted-volume names. |
| CPU | Per-process CPU time in Activity Monitor units, where one fully occupied logical core is 100%. |
| Network | Per-process and system counters with download and upload kept separate. Missing coverage is shown as unavailable, not as zero. |
| File activity | Open file descriptors for the selected application, combined with macOS FSEvents observations. A file-system change cannot be conclusively attributed to that application. |
| Drive health | The fields macOS exposes through `diskutil -plist`; unsupported values remain unavailable. |

The current implementation does **not** claim exact process-to-volume write
attribution. Application I/O and physical-device throughput are related views,
not a fabricated causal link.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode 16 or a compatible command-line toolchain)
- XcodeGen 2.42 or later when regenerating the Xcode project

## Build the macOS App

```bash
git clone git@github.com:jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild \
  -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp \
  -configuration Release \
  -derivedDataPath .derivedData \
  build
open .derivedData/Build/Products/Release/FindDiskKiller.app
```

The Xcode build produces the real signed app bundle. It embeds the dormant trace
helper and its LaunchDaemon property list at the locations required by
`SMAppService`. The app only checks helper status at launch. It does not register
the helper or request administrator approval automatically.

The SwiftPM executable remains available for Core development, but it does not
contain the app-bundle helper layout:

```bash
swift run FindDiskKiller
```

## Test

```bash
swift test
```

The test suite covers sampling arithmetic, Activity Monitor CPU semantics,
network gaps, process hover state, open-file limits, FSEvents retention,
multi-window observation leases, volume identity, disk-health parsing, command
timeouts, and localization consistency.

## Privacy and Permissions

FindDiskKiller processes monitoring data locally. The current codebase does not
send telemetry, upload file paths, or install an Endpoint Security extension.
The Xcode app bundle contains a signed privileged helper with a version-only XPC
handshake, but it is not registered automatically and cannot run arbitrary
commands, receive paths, or start `fs_usage`. A later tracing workflow must only
request registration after an explicit user action.

macOS may restrict visibility into protected processes and paths. The interface
reports partial or unavailable coverage explicitly. Recent file changes come
from system-wide FSEvents and therefore indicate that a location changed, not
which process caused the change.

## Repository Layout

```text
Sources/
  CFindDiskKiller/       Low-level macOS sampling bridge
  FindDiskKillerCore/    Sampling, aggregation, and health models
  FindDiskKillerApp/     SwiftUI application and localized resources
  FindDiskKillerTraceProtocol/  Minimal shared XPC contract
  FindDiskKillerTraceHelper/  Signed, version-only XPC helper entry point
AppConfig/               App, helper, signing, and LaunchDaemon metadata
Tests/
  FindDiskKillerCoreTests/
docs/
```

`project.yml` is the source of truth for the generated Xcode project. SwiftPM
continues to own the Core library and unit tests.

The current product and implementation plans are available in Chinese:

- [Product and technical plan](docs/find-disk-killer-product-and-technical-plan.zh-CN.md)
- [Deep tracing and SSD health plan](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.zh-CN.md)

Third-party application marks are used only to identify observed software. See
[THIRD_PARTY_ASSETS.md](Sources/FindDiskKillerApp/Resources/THIRD_PARTY_ASSETS.md)
for pinned sources and license details.
