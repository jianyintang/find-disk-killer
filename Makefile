.PHONY: project test test-ci test-agent-cleanup-fixtures test-privileged lint release

CI_LOCAL_ONLY_TESTS = FindDiskKillerCoreTests\.agentStorage|FindDiskKillerAppTests\.codexJSONRPCUsesOfficialDeleteAndVerifiesNotFound|recorder(RetriesABucketAfterATransactionLockFailure|AcceptsTheNextMinuteWhileThePreviousMinuteAwaitsRetry|BoundsPendingMinutesDuringASustainedWriteFailure)|scanStartsEveryDetectedSourceWithoutWaitingForAFixedWorkerQueue|fileChangeWatcherReportsChangesWithoutProcessAttribution|forceStopPrecedesReply

project:
	SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate

test:
	@echo "Running non-privileged unit tests (the App and Trace Helper will not be launched)."
	swift test --no-parallel

test-ci:
	CI_LOCAL_ONLY_TESTS='$(CI_LOCAL_ONLY_TESTS)' bash scripts/test-ci.sh

test-agent-cleanup-fixtures:
	/bin/zsh scripts/verify-agent-cleanup-fixtures.sh

test-privileged:
	@test "$(ALLOW_PRIVILEGED_TEST)" = "1" || (echo "Refusing to launch the privileged Helper test. Re-run once with ALLOW_PRIVILEGED_TEST=1 after installing the signed release App." >&2; exit 64)
	ALLOW_PRIVILEGED_TEST=1 /bin/bash scripts/verify-installed-trace-helper.sh

lint:
	plutil -lint Sources/FindDiskKillerApp/Resources/PrivacyInfo.xcprivacy
	@for file in Sources/FindDiskKillerApp/Resources/*.lproj/Localizable.strings; do plutil -lint "$$file"; done
	bash -n scripts/create-dmg.sh scripts/prepare-claude-cleanup-runtime.sh scripts/release.sh scripts/test-ci.sh scripts/verify-release.sh scripts/verify-installed-trace-helper.sh
	xcrun swiftc -typecheck scripts/render-dmg-background.swift

release:
	@test -n "$(VERSION)" || (echo "VERSION is required" >&2; exit 64)
	@test -n "$(BUILD_NUMBER)" || (echo "BUILD_NUMBER is required" >&2; exit 64)
	@test -n "$(SPARKLE_PUBLIC_ED_KEY)" || (echo "SPARKLE_PUBLIC_ED_KEY is required" >&2; exit 64)
	@test -n "$(RELEASE_NOTES_FILE)" || (echo "RELEASE_NOTES_FILE is required" >&2; exit 64)
	VERSION="$(VERSION)" \
	BUILD_NUMBER="$(BUILD_NUMBER)" \
	SPARKLE_PUBLIC_ED_KEY="$(SPARKLE_PUBLIC_ED_KEY)" \
	SPARKLE_KEY_ACCOUNT="$(SPARKLE_KEY_ACCOUNT)" \
	RELEASE_NOTES_FILE="$(RELEASE_NOTES_FILE)" \
	/bin/bash scripts/release.sh
