<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="136" height="136" alt="FindDiskKiller app icon">
  <h1>FindDiskKiller</h1>
  <p><strong>See what keeps using your disk.</strong></p>
  <p>A native macOS workspace for application disk I/O, CPU, network, file activity, and drive-health evidence.</p>
  <p>
    <a href="README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> ·
    <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.es.md">Español</a> ·
    <a href="README.pt-BR.md">Português (Brasil)</a> ·
    <a href="README.ru.md">Русский</a>
  </p>
  <p><strong>macOS 14+ · Apple silicon & Intel · Local processing · 10 interface languages</strong></p>
  <p>
    <a href="https://finddiskkiller.com/en/download/">Download</a> ·
    <a href="https://finddiskkiller.com/en/">Website</a> ·
    <a href="docs/find-disk-killer-product-and-technical-plan.md">Product model</a> ·
    <a href="SUPPORT.md">Support</a> ·
    <a href="PRIVACY.md">Privacy</a>
  </p>
</div>

---

<p align="center">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="FindDiskKiller Now workspace showing sustained disk activity, resource trends, and the leading apps.">
</p>
<p align="center"><sub>Find sustained disk activity and identify the apps behind it.</sub></p>

FindDiskKiller is built for the moment when your Mac is warm, the disk is busy,
and a process list alone does not explain why. It keeps the investigation
application-centered: identify sustained activity, inspect the responsible
application, then move into its CPU, disk, network, files, and storage context
without assembling the story across several tools.

## What You Can See

| Workspace | What it gives you |
| --- | --- |
| **Applications** | Five-second CPU, reads, writes, download, and upload; sortable and resizable live columns; native app icons |
| **Timelines** | Straight-line one-minute, 15-minute, and one-hour history with precise hover values |
| **Process details** | Independent windows for comparing application CPU, disk, network, and file evidence |
| **File Activity** | Current open locations and directories changed during the last five minutes |
| **File access trace** | On-demand requested read/write totals, five-second rates, session peaks, active files, and verified process sessions |
| **Disks** | Mounted-volume names mapped to physical-device throughput, including external storage |
| **Drive health** | Native NVMe/SMART evidence such as temperature, host writes, wear, spare capacity, power history, and errors when macOS exposes it |
| **Menu bar** | A quiet, lightweight view of current activity without notification noise |
| **Period reports** | Optional local aggregate history with 7-day, 30-day, and one-year trends, coverage, comparisons, and leading applications |

## A Complete Investigation, Visually

### Start with the responsible app

CPU, disk I/O, download, and upload remain separate so one busy resource does
not hide another. Current values use the latest five seconds, and each app can
open in an independent detail window.

<p align="center">
  <img src="docs/assets/screenshots/app-codex-overview.webp" width="100%" alt="Codex app detail showing CPU, disk I/O, and network timelines.">
</p>

### Move from locations to bounded file evidence

See locations an app currently has open and directories changed in the last
five minutes. When that context is not enough, explicitly start a time-limited
file or folder trace and inspect requested reads, writes, active files, and
verified process sessions.

<p align="center">
  <img src="docs/assets/screenshots/app-codex-file-activity.webp" width="100%" alt="Codex File Activity view showing related locations, writable folders, and recent changes.">
</p>

<p align="center">
  <img src="docs/assets/screenshots/folder-access-trace.webp" width="100%" alt="Bounded folder trace showing requested read and write rates, active files, and accessing processes.">
</p>

### Finish with the storage context

Map familiar mounted-volume names to physical-device throughput, then inspect
the SMART or NVMe health evidence that macOS and the drive actually expose.

<p align="center">
  <img src="docs/assets/screenshots/disk-live-activity.webp" width="100%" alt="Disks workspace showing physical-device throughput, mounted volumes, and hardware diagnostics.">
</p>

<p align="center">
  <img src="docs/assets/screenshots/disk-health.webp" width="100%" alt="Disk Health view showing SMART status, wear, temperature, host writes, power history, and media errors.">
</p>

## Measurement Without False Precision

FindDiskKiller keeps macOS evidence sources separate:

- **Application disk I/O** comes from per-process counters and covers all
  storage used by that process.
- **Device throughput** comes from physical storage counters and is shown
  through names people recognize, such as `Macintosh HD` or `ExternalSSD`.
- **Recent changes** show that macOS observed a location changing; they do not
  identify the writer by themselves.
- **File access traces** measure bytes requested through successful system
  calls. Cache, APFS writeback, compression, copy-on-write, memory mapping, and
  coverage gaps mean those values are not physical NAND writes.
- **Drive health** contains only fields macOS actually reports. Missing values
  remain unavailable instead of becoming zero.

The app does **not** claim exact process-to-physical-device byte attribution.
Related measurements are presented together without forcing them to add up.

## Privacy and Permissions

Monitoring and analysis happen locally. The current release contains no ads,
telemetry, analytics, or third-party tracking SDKs, and it does not upload
process activity, file paths, monitoring history, or disk serial numbers.

Long-term history is off by default. When enabled, per-second samples are first
aggregated in memory and saved in at most one SQLite transaction per minute.
Minute detail is retained for 24 hours; longer reports use 15-minute and hourly
rollups. Strict 7-day, 30-day, and one-local-calendar-year retention options use
automatic 32 MB, 64 MB, and 128 MB storage budgets, with a 160 MB absolute cap.
The history database excludes PIDs, full paths, per-second samples, file-trace
detail, and disk serial numbers, and can be cleared from Settings at any time.

The native macOS login item can start FindDiskKiller quietly in the menu bar.
Opening the main window after login is a separate user-controlled option.

Basic monitoring does not request administrator approval. When you explicitly
start a file or folder trace, macOS may ask you to approve FindDiskKiller's
signed background component. The helper can supervise only a bounded
`/usr/bin/fs_usage` session with a fixed command shape; it cannot execute a
shell or arbitrary command. It can be stopped and removed from Settings.

Read the complete [Privacy Policy](PRIVACY.md) and [Security Policy](SECURITY.md).

## Requirements

- macOS 14 or later
- Apple silicon or Intel Mac
- An administrator account only when enabling on-demand file access tracing

## Install

When available, official website releases are distributed as universal2,
Developer ID signed, Apple-notarized disk images.

1. Download the latest DMG from the [official website](https://finddiskkiller.com/en/download/).
2. Open it and drag FindDiskKiller to Applications.
3. Launch FindDiskKiller from Applications.

Published releases include a SHA-256 checksum. Never bypass Gatekeeper for a
package that fails signature or notarization validation.

## Build and Test

XcodeGen is the source of truth for the Xcode project:

Development requires Xcode 16 or later and XcodeGen 2.42.0 or later. The
following build disables code signing, so it does not require the maintainer's
Developer ID certificate:

```bash
git clone https://github.com/jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild \
  -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build
```

Run the core test suite:

```bash
make test
```

This target is fully non-privileged: it does not launch the App, register the
Trace Helper, or request an administrator password. Helper registration and
recovery behavior are covered by dependency-injected unit tests.

The unsigned development build can validate the base monitoring experience,
but it cannot complete privileged file or folder tracing. The App and helper
authenticate each other against the maintainer's Team ID, so that workflow must
be verified with an official signed build. Approving the background component
and granting Full Disk Access for protected locations are separate macOS
permissions; one does not imply the other.

Maintainers can create a signed, notarized website release from a clean commit:

```bash
make lint test
make release VERSION=1.0.0 BUILD_NUMBER=100
```

The release pipeline builds universal2 App and helper binaries, verifies
Hardened Runtime and trusted timestamps, creates a signed DMG, submits it for
Apple notarization, staples the ticket, runs Gatekeeper checks, and writes
`SHA256SUMS`. Artifacts produced with `SKIP_NOTARIZATION=1` are local rehearsals
and must never be published.

On a release host without Finder automation permission, reuse a previously
approved installer layout without opening Finder:

```bash
DMG_TEMPLATE=artifacts/FindDiskKiller-1.0.1-101/FindDiskKiller-1.0.1.dmg \
  make release VERSION=1.0.2 BUILD_NUMBER=102
```

Before publishing, install the exact signed release app in `/Applications` and
run the privileged tracing gate once. This gate is deliberately separate from
automated tests and requires an explicit opt-in:

```bash
EXPECTED_VERSION=1.0.3 EXPECTED_BUILD=103 ALLOW_PRIVILEGED_TEST=1 \
  make test-privileged
```

The gate verifies the embedded helper identity, performs a real file-I/O trace, confirms the launchd service is running, and rejects any new launch-constraint violation.
An attempt marker prevents an accidental second run for the same version and
build. A maintainer can set `FORCE_PRIVILEGED_TEST=1` only after diagnosing a
failed first attempt.

## Architecture

```text
Sources/
  CFindDiskKiller/              Low-level macOS sampling bridge
  CFindDiskKillerTrace/         Thread-to-process identity bridge
  FindDiskKillerCore/           Models, aggregation, and health parsing
  FindDiskKillerApp/            SwiftUI application and resources
  FindDiskKillerTraceProtocol/  Bounded XPC contract
  FindDiskKillerTraceHelper/    Signed fixed-purpose helper
AppConfig/                      Signing, bundle, and helper metadata
Tests/                          Core and contract tests
docs/                           Product, tracing, and release documentation
```

The real distribution artifact is the Xcode-built `.app`; the SwiftPM
executable does not contain the signed helper bundle layout.

## Documentation

- [Product and Technical Plan](docs/find-disk-killer-product-and-technical-plan.md)
- [Deep File Tracing and SSD Health Plan](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Website Release Checklist](docs/website-release-checklist.md)
- [Contributing](CONTRIBUTING.md)
- [Support](SUPPORT.md)
- [Privacy](PRIVACY.md)
- [Security](SECURITY.md)
- [Third-Party Notices](THIRD_PARTY_NOTICES.md)

## Support and License

Use [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) for
ordinary support. Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new)
and remove sensitive paths, usernames, and serial numbers from diagnostics.

FindDiskKiller is open source under the [MIT License](LICENSE). Third-party
application marks are used only to identify observed software and do not imply
affiliation or endorsement.
