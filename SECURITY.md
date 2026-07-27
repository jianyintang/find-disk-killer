# Security Policy

## Supported Versions

Security fixes are provided for the latest published FindDiskKiller release.
Users should update to the latest signed and notarized version before reporting
an issue that may already be resolved.

## Reporting a Vulnerability

Do not disclose a vulnerability or sensitive machine data in a public issue.
Use GitHub's private vulnerability reporting for this repository:

https://github.com/jianyintang/find-disk-killer/security/advisories/new

Include the affected version, macOS version, reproduction steps, impact, and a
minimal proof of concept. Do not include unrelated file paths, credentials,
disk serial numbers, or monitoring output.

## Privileged Component Boundary

FindDiskKiller's optional trace component is registered only after an explicit
user action. The XPC connection verifies the signing identity of both peers.
The component accepts bounded, structured requests and can only launch
`/usr/bin/fs_usage` with a fixed argument shape. It does not execute a shell or
accept an arbitrary executable, path, environment, or command line.

## Optional Monitoring History

Saved monitoring history is disabled by default and remains local. When the
user enables it, aggregate data is stored under
`~/Library/Application Support/com.jianyintang.FindDiskKiller/History` in a
`0700` directory with `0600` database, WAL, and SHM files. The database excludes
PIDs, complete executable and file paths, trace records, disk serial numbers,
and per-second samples. Path-derived identities use an installation-specific
Keychain HMAC key rather than a reversible or unsalted path hash.

Diagnostic summaries must not include paths, application lists, resource
measurements, or device serial numbers. Clearing all saved history removes the
SQLite sidecar files and rotates the history identity key.

Release artifacts must be signed with the documented Developer ID identity,
notarized by Apple, stapled, and published with a SHA-256 checksum.
