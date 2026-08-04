<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="FindDiskKiller app icon">
  <h1>FindDiskKiller</h1>
  <p><strong>See what keeps using your disk.</strong></p>
  <p>A native macOS investigation workspace for finding the app, files, and device behind sustained disk activity.</p>
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
  <p><strong>macOS 14+ · Apple silicon & Intel · 100% local processing</strong></p>
  <p>
    <a href="https://finddiskkiller.com/en/download/"><strong>Download for macOS</strong></a> ·
    <a href="https://finddiskkiller.com/en/">Website</a> ·
    <a href="https://finddiskkiller.com/en/how-it-works/">How it works</a> ·
    <a href="PRIVACY.md">Privacy</a> ·
    <a href="SUPPORT.md">Support</a>
  </p>
</div>

---

<p align="center">
  <a href="docs/assets/screenshots/overview-sustained-activity.webp">
    <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="FindDiskKiller Now workspace showing sustained disk activity, resource trends, and leading applications.">
  </a>
</p>
<p align="center"><sub>Start with the signal: see sustained activity before you investigate its cause.</sub></p>

FindDiskKiller is for the moment when your Mac is warm, the disk is busy, and a process list does not explain why. It keeps the investigation in one path: identify the application, inspect the locations it touches, then start a bounded trace when you need direct file evidence.

## Follow the evidence

### 1. Find the application

Compare CPU, disk I/O, network, memory, and time-range trends in the application workspace. Sustained activity is easier to understand when the evidence stays attached to the app that produced it.

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp">
    <img src="docs/assets/screenshots/app-codex-overview.webp" width="100%" alt="Codex application overview with CPU, disk I/O, network, memory, and application activity trends.">
  </a>
</p>
<p align="center"><sub>Ask first: which application is keeping the disk busy, and is the activity sustained?</sub></p>

### 2. Follow it to the locations

File Activity shows related locations, writable folders, open files, and recent changes. It gives you a useful next question without pretending that a changed path alone proves who wrote it.

<p align="center">
  <a href="docs/assets/screenshots/app-codex-file-activity.webp">
    <img src="docs/assets/screenshots/app-codex-file-activity.webp" width="100%" alt="Codex File Activity showing related locations, writable folders, open files, and recent changes.">
  </a>
</p>
<p align="center"><sub>Move from the application to the folders and files involved.</sub></p>

### 3. Trace only when you need proof

Start a time-bounded folder or file trace explicitly. The trace reports requested reads and writes, active files, rates, and the verified process sessions responsible for the requests.

<p align="center">
  <a href="docs/assets/screenshots/folder-access-trace.webp">
    <img src="docs/assets/screenshots/folder-access-trace.webp" width="100%" alt="A bounded folder trace showing requested read and write rates, active files, recent events, and accessing processes.">
  </a>
</p>
<p align="center"><sub>Use direct tracing as a focused investigation, not as a permanent background watcher.</sub></p>

## One workspace for the next question

- **Now and Applications** show who is active across CPU, disk, and network signals.
- **File Activity and folder tracing** show where requests are happening and which verified sessions made them.
- **Storage Map** explains how space is distributed across volumes, applications, developer tools, simulators, containers, and AI Agent data.
- **Disks and History** connect mounted volumes to physical-device activity and preserve longer-term trends.

AI Storage is explicit and reviewable. Codex and Claude data is measured only after you ask for analysis, attributed where the provider exposes a reliable identity, and never deleted by guessing from a path or writing directly to a database. Active or changed sessions remain protected.

## Measurements stay honest

FindDiskKiller keeps measurements with different meanings separate:

- Application I/O is process-requested traffic; it is not the same as physical NAND traffic.
- Physical-device throughput cannot be assigned exactly to one process, so app totals do not need to equal device totals.
- A recently changed location proves that macOS observed a change, not who caused it.
- AI storage attribution is a labelled logical estimate, not a promise of immediate physical reclaim.

Missing, partial, or unsupported evidence is shown as unavailable rather than replaced with zero.

## Private by design

Monitoring, analysis, and display happen on your Mac. The current release uploads no process names, file paths, disk serial numbers, or monitoring history, and includes no ads, telemetry, analytics, or third-party tracking SDKs.

Basic CPU, disk, network, volume, and process monitoring needs no administrator approval. macOS may ask for approval only after you explicitly start file or directory tracing; protected locations may also require Full Disk Access. You control when tracing starts and stops.

Read the complete [Privacy Policy](PRIVACY.md) and [Security Policy](SECURITY.md).

## Install

1. Download the latest signed and notarized DMG from the [official website](https://finddiskkiller.com/en/download/).
2. Open it and drag FindDiskKiller into Applications.
3. Launch FindDiskKiller from Applications.

Official releases support Apple silicon and Intel Macs and include a SHA-256 checksum. Do not bypass Gatekeeper if signature or notarization validation fails.

## Build and test

<details>
<summary><strong>Build FindDiskKiller from source</strong></summary>

Development requires Xcode 16+ and XcodeGen 2.42.0+.

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
make test
```

The unsigned build covers basic monitoring but cannot complete privileged file tracing, which requires officially signed App and helper identities.

</details>

## Documentation

- [Product and Technical Plan](docs/find-disk-killer-product-and-technical-plan.md)
- [Deep File Tracing and SSD Health Plan](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Website Release Checklist](docs/website-release-checklist.md)
- [Contributing](CONTRIBUTING.md)
- [Third-Party Notices](THIRD_PARTY_NOTICES.md)

## Support and license

Use [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) for questions, bugs, and feature requests. Report vulnerabilities privately through [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new); remove sensitive paths, usernames, and disk serial numbers before submitting diagnostics or screenshots.

FindDiskKiller is open source under the [MIT License](LICENSE).
