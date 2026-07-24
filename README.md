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
    <a href="https://github.com/jianyintang/find-disk-killer/releases/latest">Download</a> ·
    <a href="docs/find-disk-killer-product-and-technical-plan.md">Product model</a> ·
    <a href="SUPPORT.md">Support</a> ·
    <a href="PRIVACY.md">Privacy</a>
  </p>
</div>

---

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

## One Investigation, One Context

```text
Sustained activity
        |
        v
Leading application  -->  CPU / disk / download / upload
        |
        v
Open files and recent changes
        |
        v
Optional bounded file or folder trace
        |
        v
Physical device and available health evidence
```

The UI is designed for repeated investigation: CPU appears first, reads and
writes stay separate, download and upload stay separate, current values use the
latest five seconds, lists pause their visual reordering while you inspect a
row, and process details open in independent windows.

## Measurement Without False Precision

FindDiskKiller keeps macOS evidence sources separate:

- **Application disk I/O** comes from per-process counters and covers all
  storage used by that process.
- **Device throughput** comes from physical storage counters and is shown
  through names people recognize, such as `Macintosh HD` or `JianDisk`.
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

Official website releases are distributed as universal2, Developer ID signed,
Apple-notarized disk images.

1. Download the latest DMG from [Releases](https://github.com/jianyintang/find-disk-killer/releases/latest).
2. Open it and drag FindDiskKiller to Applications.
3. Launch FindDiskKiller from Applications.

Published releases include a SHA-256 checksum. Never bypass Gatekeeper for a
package that fails signature or notarization validation.

## Build and Test

XcodeGen is the source of truth for the Xcode project:

```bash
git clone git@github.com:jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild \
  -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  build
```

Run the core test suite:

```bash
swift test
```

Create a signed, notarized website release from a clean commit:

```bash
make lint test
make release VERSION=1.0.0 BUILD_NUMBER=100
```

The release pipeline builds universal2 App and helper binaries, verifies
Hardened Runtime and trusted timestamps, creates a signed DMG, submits it for
Apple notarization, staples the ticket, runs Gatekeeper checks, and writes
`SHA256SUMS`. Artifacts produced with `SKIP_NOTARIZATION=1` are local rehearsals
and must never be published.

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
- [Support](SUPPORT.md)
- [Privacy](PRIVACY.md)
- [Security](SECURITY.md)
- [Third-Party Notices](THIRD_PARTY_NOTICES.md)

## Support and License

Use [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) for
ordinary support. Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new)
and remove sensitive paths, usernames, and serial numbers from diagnostics.

FindDiskKiller is distributed under the repository's
[All Rights Reserved license](LICENSE). Third-party application marks are used
only to identify observed software and do not imply affiliation or endorsement.
