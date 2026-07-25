# Website Release Checklist

This checklist is a release gate. A build is not public until every required
item is backed by an artifact or a test record.

## One-Time Setup

- Confirm ownership of the product name, domain, bundle identifier, and artwork.
- Keep the Developer ID Application certificate and private key access limited.
- Store notarization credentials in Keychain, never in the repository:

  ```bash
  xcrun notarytool store-credentials FindDiskKiller-notary \
    --apple-id YOUR_APPLE_ID \
    --team-id Y3A8BJ4475 \
    --password YOUR_APP_SPECIFIC_PASSWORD
  ```

- Enable GitHub private vulnerability reporting.
- Publish `PRIVACY.md`, `SUPPORT.md`, and the SHA-256 checksum over HTTPS.

## Build and Sign

- Start from a clean, reviewed commit on `main`.
- Choose a monotonically increasing version and build number.
- Run:

  ```bash
  make lint test
  make release VERSION=1.0.0 BUILD_NUMBER=100
  ```

- Do not publish artifacts created with `SKIP_NOTARIZATION=1` or
  `ALLOW_DIRTY=1`.
- Retain the `.xcarchive`, DMG, `SHA256SUMS`, source commit, and App/DMG
  notarization submission identifiers for the release record.

## Clean-Mac Acceptance

- Install from the DMG on a Mac that has never run FindDiskKiller.
- Verify Gatekeeper opens the app without bypass instructions.
- Verify basic monitoring never asks for administrator approval.
- Start one file trace and verify there is a single understandable approval
  path, cancellation works, and approval is not repeatedly requested.
- Verify stop, navigation away, app quit, sleep/wake, and force quit leave no
  `fs_usage` process running.
- Verify helper upgrade from the previous public version and explicit removal
  in Settings.
- Verify Apple silicon and Intel binaries, macOS 14, and the current macOS.
- Check all ten app languages, VoiceOver, keyboard navigation, reduced
  transparency, increased contrast, and the minimum supported window size.
- Test internal, external, APFS encrypted, removable, and unsupported SMART
  devices; missing data must remain unavailable rather than zero.

## Website and Rollout

- Publish the exact version, release date, minimum macOS version, release notes,
  DMG size, SHA-256 checksum, privacy policy, and support link.
- Serve the DMG over HTTPS with the correct content type and no HTML rewriting.
- Download the public file once and verify its checksum, stapled ticket, and
  Gatekeeper assessment again.
- Keep the previous known-good release available for recovery, but never offer
  an automatic downgrade over a newer installed helper.
- Monitor support reports during the initial rollout. Pause distribution for
  signature, notarization, launch, helper lifecycle, or data-integrity failures.

Automatic updates are intentionally not part of the first website release.
Adding Sparkle requires a separately reviewed EdDSA key lifecycle, signed appcast,
rollback policy, update-host availability plan, and privacy-policy update.
