.PHONY: project test test-privileged lint release

project:
	xcodegen generate

test:
	@echo "Running non-privileged unit tests (the App and Trace Helper will not be launched)."
	swift test --no-parallel

test-privileged:
	@test "$(ALLOW_PRIVILEGED_TEST)" = "1" || (echo "Refusing to launch the privileged Helper test. Re-run once with ALLOW_PRIVILEGED_TEST=1 after installing the signed release App." >&2; exit 64)
	ALLOW_PRIVILEGED_TEST=1 /bin/bash scripts/verify-installed-trace-helper.sh

lint:
	plutil -lint Sources/FindDiskKillerApp/Resources/PrivacyInfo.xcprivacy
	@for file in Sources/FindDiskKillerApp/Resources/*.lproj/Localizable.strings; do plutil -lint "$$file"; done
	bash -n scripts/create-dmg.sh scripts/release.sh scripts/verify-release.sh scripts/verify-installed-trace-helper.sh
	xcrun swiftc -typecheck scripts/render-dmg-background.swift

release:
	@test -n "$(VERSION)" || (echo "VERSION is required" >&2; exit 64)
	@test -n "$(BUILD_NUMBER)" || (echo "BUILD_NUMBER is required" >&2; exit 64)
	VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" /bin/bash scripts/release.sh
