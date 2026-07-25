#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: $0 <FindDiskKiller.app> [FindDiskKiller.dmg] [--notarized]" >&2
}

[[ $# -ge 1 ]] || { usage; exit 64; }

app_path=$1
shift
dmg_path=""
require_notarization=0

for argument in "$@"; do
    if [[ "$argument" == "--notarized" ]]; then
        require_notarization=1
    elif [[ -z "$dmg_path" ]]; then
        dmg_path=$argument
    else
        usage
        exit 64
    fi
done

[[ -d "$app_path" ]] || { echo "App bundle not found: $app_path" >&2; exit 1; }

info_plist="$app_path/Contents/Info.plist"
helper="$app_path/Contents/Library/LaunchDaemons/com.jianyintang.FindDiskKiller.TraceHelper"
helper_plist="$app_path/Contents/Library/LaunchDaemons/com.jianyintang.FindDiskKiller.TraceHelper.plist"
privacy_manifest="$app_path/Contents/Resources/PrivacyInfo.xcprivacy"
third_party_notices="$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"

for required_path in \
    "$info_plist" \
    "$helper" \
    "$helper_plist" \
    "$privacy_manifest" \
    "$third_party_notices"; do
    [[ -e "$required_path" ]] || { echo "Required release payload missing: $required_path" >&2; exit 1; }
done

plutil -lint "$info_plist" "$helper_plist" "$privacy_manifest"

bundle_identifier=$(plutil -extract CFBundleIdentifier raw "$info_plist")
[[ "$bundle_identifier" == "com.jianyintang.FindDiskKiller" ]] || {
    echo "Unexpected bundle identifier: $bundle_identifier" >&2
    exit 1
}

privacy_tracking=$(plutil -extract NSPrivacyTracking raw "$privacy_manifest")
[[ "$privacy_tracking" == "false" ]] || {
    echo "Privacy manifest must declare tracking as disabled" >&2
    exit 1
}

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --verify --strict --verbose=2 "$helper"

app_signature=$(codesign -dvvv "$app_path" 2>&1)
helper_signature=$(codesign -dvvv "$helper" 2>&1)
team_identifier=$(awk -F= '/^TeamIdentifier=/{print $2}' <<<"$app_signature")
[[ "$team_identifier" == "Y3A8BJ4475" ]] || {
    echo "Unexpected signing team: ${team_identifier:-missing}" >&2
    exit 1
}
for signature in "$app_signature" "$helper_signature"; do
    grep -Fq "Authority=Developer ID Application: Jianyin Tang (Y3A8BJ4475)" <<<"$signature" || {
        echo "Release payload is not signed with the expected Developer ID identity" >&2
        exit 1
    }
    grep -Eq '^Runtime Version=|^flags=.*runtime' <<<"$signature" || {
        echo "Release payload is missing Hardened Runtime" >&2
        exit 1
    }
    grep -q '^Timestamp=' <<<"$signature" || {
        echo "Release payload is missing a trusted signing timestamp" >&2
        exit 1
    }
done

require_universal_binary() {
    local binary=$1
    local architectures
    architectures=$(lipo -archs "$binary")
    [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
        echo "Release binary is not universal2: $binary ($architectures)" >&2
        exit 1
    }
}

require_universal_binary "$app_path/Contents/MacOS/FindDiskKiller"
require_universal_binary "$helper"

if [[ -n "$dmg_path" ]]; then
    [[ -f "$dmg_path" ]] || { echo "Disk image not found: $dmg_path" >&2; exit 1; }
    codesign --verify --verbose=2 "$dmg_path"
fi

if [[ $require_notarization -eq 1 ]]; then
    if [[ -n "$dmg_path" ]]; then
        xcrun stapler validate "$dmg_path"
        dmg_assessment=""
        if ! dmg_assessment=$(spctl \
            --assess \
            --type open \
            --context context:primary-signature \
            --verbose=2 \
            "$dmg_path" 2>&1); then
            if command -v syspolicy_check >/dev/null \
                && grep -Fq "One or more parameters passed to a function were not valid" \
                    <<<"$dmg_assessment"; then
                echo "spctl cannot assess disk images on this macOS version; continuing with the stapled DMG ticket and App distribution check." >&2
            else
                echo "$dmg_assessment" >&2
                exit 1
            fi
        elif [[ -n "$dmg_assessment" ]]; then
            echo "$dmg_assessment"
        fi
    fi
    if command -v syspolicy_check >/dev/null; then
        syspolicy_check distribution "$app_path"
    else
        spctl --assess --type execute --verbose=2 "$app_path"
    fi
fi

version=$(plutil -extract CFBundleShortVersionString raw "$info_plist")
build=$(plutil -extract CFBundleVersion raw "$info_plist")
echo "Verified FindDiskKiller $version ($build), team $team_identifier"
