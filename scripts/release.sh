#!/usr/bin/env bash

set -euo pipefail

root_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=${VERSION:-}
build_number=${BUILD_NUMBER:-}
sign_identity=${SIGN_IDENTITY:-Developer ID Application: Jianyin Tang (Y3A8BJ4475)}
notary_profile=${NOTARY_KEYCHAIN_PROFILE:-FindDiskKiller-notary}
output_root=${OUTPUT_DIR:-$root_directory/artifacts}
skip_notarization=${SKIP_NOTARIZATION:-0}
sparkle_public_key=${SPARKLE_PUBLIC_ED_KEY:-}
sparkle_key_account=${SPARKLE_KEY_ACCOUNT:-com.jianyintang.FindDiskKiller}
release_notes_file=${RELEASE_NOTES_FILE:-}

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]] || {
    echo "VERSION must be a release version such as 1.0.0" >&2
    exit 64
}
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || {
    echo "BUILD_NUMBER must be a positive integer" >&2
    exit 64
}
(( build_number > 111 )) || {
    echo "BUILD_NUMBER must be greater than the last public build (111) for Sparkle releases" >&2
    exit 64
}
[[ -n "$sparkle_public_key" ]] || {
    echo "SPARKLE_PUBLIC_ED_KEY is required (public key only; the private key stays in Keychain)" >&2
    exit 64
}
if ! decoded_key_length=$(printf '%s' "$sparkle_public_key" \
    | /usr/bin/base64 -D 2>/dev/null \
    | wc -c \
    | tr -d ' '); then
    decoded_key_length=0
fi
[[ "$decoded_key_length" == "32" ]] || {
    echo "SPARKLE_PUBLIC_ED_KEY must be a base64-encoded 32-byte Ed25519 public key" >&2
    exit 64
}
[[ -f "$release_notes_file" ]] || {
    echo "RELEASE_NOTES_FILE must point to the Markdown release notes for this version" >&2
    exit 64
}

for command_name in git swift xcodegen xcodebuild codesign hdiutil ditto shasum xmllint; do
    command -v "$command_name" >/dev/null || {
        echo "Required command is unavailable: $command_name" >&2
        exit 1
    }
done

if [[ -n "$(git -C "$root_directory" status --porcelain)" && ${ALLOW_DIRTY:-0} != 1 ]]; then
    echo "The worktree is not clean. Commit the release contents or set ALLOW_DIRTY=1 for a local rehearsal." >&2
    exit 1
fi

release_directory="$output_root/FindDiskKiller-$version-$build_number"
[[ ! -e "$release_directory" ]] || {
    echo "Release output already exists: $release_directory" >&2
    exit 1
}
mkdir -p "$release_directory"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/find-disk-killer-release.XXXXXX")
cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

archive_path="$release_directory/FindDiskKiller.xcarchive"
dmg_path="$release_directory/FindDiskKiller-$version.dmg"

cd "$root_directory"
swift test --no-parallel

sparkle_bin_directory=${SPARKLE_BIN_DIR:-$root_directory/.build/artifacts/sparkle/Sparkle/bin}
generate_appcast="$sparkle_bin_directory/generate_appcast"
generate_keys="$sparkle_bin_directory/generate_keys"
sign_update="$sparkle_bin_directory/sign_update"
for sparkle_tool in "$generate_appcast" "$generate_keys" "$sign_update"; do
    [[ -x "$sparkle_tool" ]] || {
        echo "Sparkle release tool not found: $sparkle_tool" >&2
        echo "Run swift package resolve, or set SPARKLE_BIN_DIR to Sparkle's bin directory." >&2
        exit 1
    }
done
keychain_public_key=$("$generate_keys" --account "$sparkle_key_account" -p | tr -d '[:space:]')
[[ "$keychain_public_key" == "$sparkle_public_key" ]] || {
    echo "SPARKLE_PUBLIC_ED_KEY does not match the private key in Keychain account $sparkle_key_account" >&2
    exit 1
}

SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate
if [[ ${ALLOW_DIRTY:-0} != 1 && -n "$(git status --porcelain)" ]]; then
    echo "XcodeGen changed tracked release files. Regenerate and commit them before releasing." >&2
    exit 1
fi
xcodebuild archive \
    -project FindDiskKiller.xcodeproj \
    -scheme FindDiskKillerApp \
    -configuration Release \
    -archivePath "$archive_path" \
    -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    SPARKLE_PUBLIC_ED_KEY="$sparkle_public_key" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM=Y3A8BJ4475 \
    ENABLE_HARDENED_RUNTIME=YES \
    ONLY_ACTIVE_ARCH=NO \
    -allowProvisioningUpdates \
    -quiet \
    archive

app_path="$archive_path/Products/Applications/FindDiskKiller.app"
export_directory="$temporary_directory/export"
xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_directory" \
    -exportOptionsPlist "$root_directory/AppConfig/DeveloperIDExportOptions.plist" \
    -allowProvisioningUpdates \
    -quiet
development_app="$temporary_directory/development-app"
mv "$app_path" "$development_app"
ditto "$export_directory/FindDiskKiller.app" "$app_path"
/bin/bash "$root_directory/scripts/verify-release.sh" "$app_path"

if [[ "$skip_notarization" != 1 ]]; then
    app_notarization_archive="$temporary_directory/FindDiskKiller-$version.zip"
    ditto -c -k --keepParent "$app_path" "$app_notarization_archive"
    app_notarization_result="$release_directory/app-notarization.json"
    xcrun notarytool submit "$app_notarization_archive" \
        --keychain-profile "$notary_profile" \
        --wait \
        --output-format json > "$app_notarization_result"
    app_notarization_status=$(plutil -extract status raw "$app_notarization_result")
    [[ "$app_notarization_status" == "Accepted" ]] || {
        echo "Apple did not accept the App notarization submission: $app_notarization_status" >&2
        exit 1
    }
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
fi

/bin/bash "$root_directory/scripts/create-dmg.sh" \
    "$app_path" \
    "$dmg_path" \
    "FindDiskKiller"
codesign --force --timestamp --sign "$sign_identity" "$dmg_path"

if [[ "$skip_notarization" == 1 ]]; then
    echo "Notarization was skipped. This artifact is for local rehearsal only." >&2
    printf '%s\n' \
        'LOCAL REHEARSAL ONLY: this disk image has not been notarized and must not be published.' \
        > "$release_directory/LOCAL_REHEARSAL_NOT_NOTARIZED.txt"
    /bin/bash "$root_directory/scripts/verify-release.sh" "$app_path" "$dmg_path"
else
    notarization_result="$release_directory/notarization.json"
    xcrun notarytool submit "$dmg_path" \
        --keychain-profile "$notary_profile" \
        --wait \
        --output-format json > "$notarization_result"
    notarization_status=$(plutil -extract status raw "$notarization_result")
    [[ "$notarization_status" == "Accepted" ]] || {
        echo "Apple did not accept the notarization submission: $notarization_status" >&2
        exit 1
    }
    xcrun stapler staple "$dmg_path"
    /bin/bash "$root_directory/scripts/verify-release.sh" "$app_path" "$dmg_path" --notarized
fi

appcast_source="$temporary_directory/appcast-source"
mkdir -p "$appcast_source"
cp "$dmg_path" "$appcast_source/"
cp "$release_notes_file" "$appcast_source/FindDiskKiller-$version.md"
"$generate_appcast" \
    --account "$sparkle_key_account" \
    --download-url-prefix "https://github.com/jianyintang/find-disk-killer/releases/download/v$version/" \
    --full-release-notes-url "https://github.com/jianyintang/find-disk-killer/releases/tag/v$version" \
    --link "https://finddiskkiller.com/en/" \
    --maximum-deltas 0 \
    --maximum-versions 3 \
    -o "$appcast_source/appcast.xml" \
    "$appcast_source"
appcast_path="$appcast_source/appcast.xml"
"$sign_update" --account "$sparkle_key_account" "$appcast_path"
"$sign_update" --account "$sparkle_key_account" --verify "$appcast_path"

appcast_build=$(xmllint --xpath \
    'string((//*[local-name()="item"]/*[local-name()="version"])[1])' \
    "$appcast_path")
appcast_version=$(xmllint --xpath \
    'string((//*[local-name()="item"]/*[local-name()="shortVersionString"])[1])' \
    "$appcast_path")
enclosure_url=$(xmllint --xpath \
    'string((//*[local-name()="item"]/*[local-name()="enclosure"]/@url)[1])' \
    "$appcast_path")
enclosure_length=$(xmllint --xpath \
    'string((//*[local-name()="item"]/*[local-name()="enclosure"]/@length)[1])' \
    "$appcast_path")
enclosure_signature=$(xmllint --xpath \
    'string((//*[local-name()="item"]/*[local-name()="enclosure"]/@*[local-name()="edSignature"])[1])' \
    "$appcast_path")
expected_enclosure_url="https://github.com/jianyintang/find-disk-killer/releases/download/v$version/$(basename "$dmg_path")"
expected_enclosure_length=$(stat -f '%z' "$dmg_path")
[[ "$appcast_build" == "$build_number" \
    && "$appcast_version" == "$version" \
    && "$enclosure_url" == "$expected_enclosure_url" \
    && "$enclosure_length" == "$expected_enclosure_length" \
    && -n "$enclosure_signature" ]] || {
    echo "Generated appcast does not match the release DMG, version, build, or URL" >&2
    exit 1
}
cp "$appcast_path" "$release_directory/appcast.xml"

(
    cd "$release_directory"
    shasum -a 256 "$(basename "$dmg_path")" appcast.xml > SHA256SUMS
)

echo "Release artifacts: $release_directory"
