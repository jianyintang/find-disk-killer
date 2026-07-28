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
- Generate the Sparkle key once on the release Mac. The private key remains in
  the login Keychain; the command prints the public key for the build setting:

  ```bash
  .build/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account com.jianyintang.FindDiskKiller
  ```

- Export exactly one plaintext key file, immediately place it in encrypted
  offline storage, then securely remove the plaintext export:

  ```bash
  .build/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account com.jianyintang.FindDiskKiller \
    -x /secure/temporary/FindDiskKiller-Sparkle-private-key
  ```

  The Sparkle tool does **not** encrypt this export. Store it in an encrypted
  password manager or encrypted offline volume. Never put it in Git, GitHub
  Actions, release assets, or shell output.

## Build and Sign

- Start from a clean, reviewed commit on `main`.
- Choose a monotonically increasing version and build number.
- Run:

  ```bash
  make lint test
  make release \
    VERSION=1.2.0 \
    BUILD_NUMBER=112 \
    SPARKLE_PUBLIC_ED_KEY='PUBLIC_KEY_PRINTED_BY_GENERATE_KEYS' \
    RELEASE_NOTES_FILE='docs/releases/1.2.0.md'
  ```

- Do not publish artifacts created with `SKIP_NOTARIZATION=1` or
  `ALLOW_DIRTY=1`.
- Confirm the release build number is greater than `111` (the last public build
  before Sparkle was added).
- Retain the `.xcarchive`, DMG, signed `appcast.xml`, `SHA256SUMS`, source commit, and App/DMG
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
- Upload the DMG, `appcast.xml`, and `SHA256SUMS` to the same GitHub Release.
  Confirm the permanent enclosure URL and
  `releases/latest/download/appcast.xml` both return the exact published files.
- Install the previous public build and verify **Check for Updates** discovers,
  downloads, verifies, and installs the new build without opening a browser.
- Verify automatic checking makes no more than one request per 24 hours while
  enabled, and that disabling it in Settings persists after relaunch.
- Start a deep trace, confirm update checks are disabled with a useful reason,
  stop the trace, and confirm updates become available only after helper ACK.
- Keep the previous known-good release available for recovery, but never offer
  an automatic downgrade over a newer installed helper.
- Monitor support reports during the initial rollout. Pause distribution for
  signature, notarization, launch, helper lifecycle, or data-integrity failures.

Do not publish if the appcast signature verification fails, the embedded public
key differs from the Keychain key, or the release script was run with rehearsal
flags. Rollback means publishing a newer signed build that restores the prior
known-good code; never replace an already published enclosure in place.
