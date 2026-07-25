#!/usr/bin/env bash

set -euo pipefail

root_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=${VERSION:-}
build_number=${BUILD_NUMBER:-}
sign_identity=${SIGN_IDENTITY:-Developer ID Application: Jianyin Tang (Y3A8BJ4475)}
notary_profile=${NOTARY_KEYCHAIN_PROFILE:-FindDiskKiller-notary}
output_root=${OUTPUT_DIR:-$root_directory/artifacts}
skip_notarization=${SKIP_NOTARIZATION:-0}

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]] || {
    echo "VERSION must be a release version such as 1.0.0" >&2
    exit 64
}
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || {
    echo "BUILD_NUMBER must be a positive integer" >&2
    exit 64
}

for command_name in git swift xcodegen xcodebuild codesign hdiutil ditto shasum; do
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
swift test
xcodegen generate
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
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$sign_identity" \
    DEVELOPMENT_TEAM=Y3A8BJ4475 \
    ENABLE_HARDENED_RUNTIME=YES \
    ONLY_ACTIVE_ARCH=NO \
    -quiet \
    archive

app_path="$archive_path/Products/Applications/FindDiskKiller.app"
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

(
    cd "$release_directory"
    shasum -a 256 "$(basename "$dmg_path")" > SHA256SUMS
)

echo "Release artifacts: $release_directory"
