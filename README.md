<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="FindDiskKiller app icon">
  <h1>FindDiskKiller</h1>
  <p><strong>See what keeps using your disk.</strong></p>
  <p>Start with application disk I/O, then follow the evidence through file activity, AI Agent storage, and physical disks.</p>
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

<a href="docs/assets/screenshots/overview-sustained-activity.webp">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="The complete FindDiskKiller Now workspace showing sustained disk activity, resource trends, and leading applications.">
</a>

<p align="center"><sub>Find sustained disk activity and identify the applications behind it. Click the image to open the original.</sub></p>

FindDiskKiller is a native macOS tool focused on one job: follow sustained disk activity from a visible signal to the applications, files, and physical devices behind it. CPU, disk, and network evidence stays application-centered, so you do not have to assemble the story across several system tools.

<p align="center">
  <strong>100%</strong> local processing　·　<strong>0</strong> data uploaded　·　<strong>10</strong> interface languages　·　<strong>macOS 14+</strong>
</p>

## Everything in One Workspace

### AI Agent Storage

Codex and Claude accumulate transcripts, subagent sessions, snapshots, visualizations, and shared databases. AI Storage starts only after an explicit click, attributes storage to individual threads or sessions, and provides a complete review before permanent deletion.

<a href="docs/assets/screenshots/ai-storage-overview.webp">
  <img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="AI Storage overview separating chat, global, and unattributed storage for Codex and Claude.">
</a>

<p align="center"><sub>Measure total provider storage first, then separate chats, global data, and unattributed space.</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/ai-storage-thread-details.webp"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="57%" alt="Codex AI Storage listing activity, subagents, and the selected thread's complete storage breakdown."></a>
  <a href="docs/assets/screenshots/ai-storage-batch-cleanup.webp"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="41%" alt="AI Agent batch cleanup review showing the selected scope and estimated immediate reclaim before permanent deletion."></a>
</p>

<p align="center"><sub>Left: attribute storage to a conversation　·　Right: review age, project, and conversation scope before permanent deletion</sub></p>

Analysis never starts automatically. Active or identity-changed sessions are skipped, and unsupported providers never fall back to direct database writes or manual transcript deletion. Claude Desktop and Cowork sessions currently remain deletable only inside Claude Desktop.

### Application Activity and File Evidence

Compare an application's CPU, disk I/O, and network trends, then move into its open locations and recently changed directories. When you need stronger evidence, explicitly start a time-bounded file or folder trace.

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp"><img src="docs/assets/screenshots/app-codex-overview.webp" width="49%" alt="Codex application detail with separate CPU, disk I/O, and network timelines."></a>
  <a href="docs/assets/screenshots/app-codex-file-activity.webp"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="49%" alt="Codex File Activity showing related locations, writable folders, and recent changes."></a>
</p>

<p align="center"><sub>Left: determine whether resource activity is sustained　·　Right: move into the locations involved</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/folder-access-trace.webp"><img src="docs/assets/screenshots/folder-access-trace.webp" width="86%" alt="A bounded folder trace showing requested read and write rates, active files, and accessing processes."></a>
</p>

<p align="center"><sub>Tracing runs only after an explicit start and shows requested I/O, active files, and verified process sessions.</sub></p>

### Physical Disks and Health

Map familiar volume names such as Macintosh HD and external drives to physical-device throughput, then inspect the SMART/NVMe health fields that macOS and the hardware actually expose.

<p align="center">
  <a href="docs/assets/screenshots/disk-live-activity.webp"><img src="docs/assets/screenshots/disk-live-activity.webp" width="49%" alt="Disks workspace showing physical-device throughput, mounted volumes, and hardware diagnostics."></a>
  <a href="docs/assets/screenshots/disk-health.webp"><img src="docs/assets/screenshots/disk-health.webp" width="49%" alt="Disk Health showing SMART status, wear, temperature, host writes, power history, and media errors."></a>
</p>

<p align="center"><sub>Left: see which physical device is busy　·　Right: inspect the health evidence the device reports</sub></p>

## No False Precision

FindDiskKiller presents related evidence together without forcing measurements with different meanings into one number:

- **Application I/O** reports process requests across storage; it is not physical NAND traffic.
- **Physical-device throughput** cannot be assigned exactly to one process, and application totals are not expected to equal device totals.
- **Recently changed locations** show that macOS observed a change; they do not identify the writer by themselves.
- **AI database attribution** is a clearly labelled logical estimate, not immediate physical disk reclaim.

Missing, partial, or unsupported evidence is shown as unavailable rather than replaced with zero.

## Privacy and Permissions

All monitoring, analysis, and display happen on the Mac. The current release uploads no process names, file paths, disk serial numbers, or monitoring history, and contains no ads, telemetry, analytics, or third-party tracking SDKs.

Basic CPU, disk, network, volume, and process monitoring needs no administrator approval. Only when you explicitly start file or directory tracing may macOS ask you to approve the signed, fixed-purpose background component; protected locations may also require Full Disk Access. You always control when tracing starts and stops.

Read the complete [Privacy Policy](PRIVACY.md) and [Security Policy](SECURITY.md).

## Install

1. Download the latest signed and notarized DMG from the [official website](https://finddiskkiller.com/en/download/).
2. Open it and drag FindDiskKiller into Applications.
3. Launch FindDiskKiller from Applications.

Official releases support Apple silicon and Intel Macs and include a SHA-256 checksum. Do not bypass Gatekeeper if signature or notarization validation fails.

## Development and Documentation

<details>
<summary><strong>Build from source and run tests</strong></summary>

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

- [Product and Technical Plan](docs/find-disk-killer-product-and-technical-plan.md)
- [Deep File Tracing and SSD Health Plan](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Website Release Checklist](docs/website-release-checklist.md)
- [Contributing](CONTRIBUTING.md)
- [Third-Party Notices](THIRD_PARTY_NOTICES.md)

## Support and License

Use [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) for questions, bugs, and feature requests. Report vulnerabilities privately through [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new); remove sensitive paths, usernames, and disk serial numbers before submitting diagnostics or screenshots.

FindDiskKiller is open source under the [MIT License](LICENSE).
