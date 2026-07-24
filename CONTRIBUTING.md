# Contributing to FindDiskKiller

Thanks for helping improve FindDiskKiller. Focused bug fixes, measurement
corrections, accessibility improvements, and well-scoped macOS compatibility
changes are welcome.

## Development Setup

You need macOS 14 or later, Xcode 16 or later, and XcodeGen 2.42.0 or later.
XcodeGen is the source of truth for the checked-in Xcode project.

```bash
git clone https://github.com/jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
swift test
xcodebuild \
  -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build
```

The unsigned build covers the application and helper compilation path and can
validate base monitoring. It cannot complete privileged file or folder tracing:
the App and helper authenticate each other against the maintainer's Team ID.
Running or packaging that workflow therefore requires an official maintainer
signature and is not expected for ordinary contributions. Background-component
approval and Full Disk Access for protected locations are separate macOS
permissions.

## Before Opening a Pull Request

- Keep changes narrowly scoped and preserve the existing Swift and SwiftUI
  patterns.
- Run `swift test` and `make lint`.
- Run `xcodegen generate` and include any resulting tracked project changes.
- Add or update focused tests when measurement, parsing, or aggregation behavior
  changes.
- Keep application I/O, physical-device throughput, recent file changes, and
  requested bytes from file traces described as distinct measurements.

For bug reports, include the FindDiskKiller version, macOS version, Mac model,
expected behavior, and reproduction steps. Remove usernames, private paths,
disk serial numbers, and other machine-specific information before attaching
screenshots or logs.
