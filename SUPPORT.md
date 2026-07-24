# FindDiskKiller Support

## System Requirements

- macOS 14 or later
- Apple silicon or Intel Mac
- An administrator account only when enabling on-demand file access tracing

## Installation

1. Download the signed and notarized DMG from the official release page.
2. Verify the published SHA-256 checksum if the download source is in doubt.
3. Open the DMG and drag FindDiskKiller to Applications.
4. Launch FindDiskKiller from Applications.

Basic monitoring starts without administrator approval. macOS asks for approval
only after you explicitly start file or folder tracing.

## Removing FindDiskKiller

1. Stop any active file access trace.
2. Open **FindDiskKiller > Settings > Data & Privacy**.
3. Choose **Disable and Remove Trace Component** if it is enabled.
4. Turn off **Launch at Login** if it is enabled.
5. Quit FindDiskKiller and move it from Applications to the Trash.

Removing the trace component first allows macOS to unregister the background
item cleanly. Monitoring data is memory-only and disappears when the app quits.
You may remove remaining preferences through your normal macOS account cleanup
process; they contain settings, not monitoring history.

## Troubleshooting

If a metric is unavailable, first check the coverage message shown by the app.
FindDiskKiller intentionally reports missing access as unavailable instead of
showing a misleading zero.

For trace approval issues, open **System Settings > General > Login Items &
Extensions** and review the FindDiskKiller background item. Do not repeatedly
remove and reinstall the app to force approval.

For support, open an issue in the
[FindDiskKiller repository](https://github.com/jianyintang/find-disk-killer/issues).
Include the app version, macOS version, Mac model, expected behavior, and exact
steps to reproduce. Redact usernames, file paths, serial numbers, and other
sensitive data before attaching screenshots or logs.
