.PHONY: project test lint release

project:
	xcodegen generate

test:
	swift test

lint:
	plutil -lint Sources/FindDiskKillerApp/Resources/PrivacyInfo.xcprivacy
	@for file in Sources/FindDiskKillerApp/Resources/*.lproj/Localizable.strings; do plutil -lint "$$file"; done
	bash -n scripts/release.sh scripts/verify-release.sh

release:
	@test -n "$(VERSION)" || (echo "VERSION is required" >&2; exit 64)
	@test -n "$(BUILD_NUMBER)" || (echo "BUILD_NUMBER is required" >&2; exit 64)
	VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" /bin/bash scripts/release.sh
