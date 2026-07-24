# FindDiskKiller Privacy Policy

Effective date: July 24, 2026

FindDiskKiller is designed to inspect activity on your Mac without sending that
activity anywhere. Monitoring and analysis happen locally on the device.

## Data Collection

FindDiskKiller does not collect, transmit, sell, or share personal data. It does
not contain advertising, analytics, telemetry, or third-party tracking SDKs.

The app may observe the following information locally to provide its features:

- process names, executable locations, process identifiers, and resource usage;
- disk, mounted-volume, CPU, and network counters exposed by macOS;
- file paths selected by you or observed during an active tracing session; and
- drive identity and health fields that macOS makes available.

This information is not uploaded. Monitoring history is held in memory and is
cleared when you quit the app or choose **Clear This Session Now**. App
preferences, such as language and sampling interval, are stored in the app's
local preferences domain.

## Permissions and the Trace Component

Basic monitoring does not request administrator approval. When you explicitly
start a file or folder trace, FindDiskKiller may ask macOS to approve its signed
background trace component. That component runs with elevated privileges only
to supervise a bounded `/usr/bin/fs_usage` session. It accepts a fixed command
shape and duration, does not accept arbitrary shell commands, and does not
receive your selected path from the app.

You can stop an active trace at any time. You can also disable and unregister
the trace component in **FindDiskKiller > Settings > Data & Privacy**. macOS may
separately require approval in Login Items or Full Disk Access for protected
locations. FindDiskKiller cannot grant those permissions on your behalf.

## Network Access

FindDiskKiller does not make automatic network requests in the current release.
Choosing a Privacy Policy, Support, Project Home, or download link opens that
website in your browser, where the website operator's privacy terms apply.

## Data Security

The app uses macOS code signing, Hardened Runtime, XPC code-signing checks, and
bounded in-memory buffers to reduce exposure. No software can guarantee
absolute security, but FindDiskKiller intentionally minimizes persistence and
does not operate a server that receives monitoring data.

## Changes and Contact

Material changes to this policy will be published with the release that
introduces them. For privacy questions, open an issue in the
[FindDiskKiller repository](https://github.com/jianyintang/find-disk-killer/issues)
without including private file paths or other sensitive data.
