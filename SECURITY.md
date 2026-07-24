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

Release artifacts must be signed with the documented Developer ID identity,
notarized by Apple, stapled, and published with a SHA-256 checksum.
