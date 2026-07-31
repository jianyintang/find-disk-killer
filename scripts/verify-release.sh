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
helper_plist="$app_path/Contents/Library/LaunchDaemons/com.jianyintang.FindDiskKiller.TraceHelper.v2.plist"
legacy_helper_plist="$app_path/Contents/Library/LaunchDaemons/com.jianyintang.FindDiskKiller.TraceHelper.plist"
privacy_manifest="$app_path/Contents/Resources/PrivacyInfo.xcprivacy"
third_party_notices="$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
provisioning_profile="$app_path/Contents/embedded.provisionprofile"
sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
claude_cleanup_helper="$app_path/Contents/MacOS/FindDiskKillerClaudeCleanupHelper"
claude_cleanup_script="$app_path/Contents/Resources/AgentCleanup/claude-cleanup-helper.mjs"
claude_cleanup_sdk="$app_path/Contents/Resources/AgentCleanup/claude-agent-sdk/sdk.mjs"

for required_path in \
    "$info_plist" \
    "$helper" \
    "$helper_plist" \
    "$legacy_helper_plist" \
    "$privacy_manifest" \
    "$third_party_notices" \
    "$sparkle_framework" \
    "$claude_cleanup_helper" \
    "$claude_cleanup_script" \
    "$claude_cleanup_sdk" \
    "$provisioning_profile"; do
    [[ -e "$required_path" ]] || { echo "Required release payload missing: $required_path" >&2; exit 1; }
done

# The Node.js runtime is resolved or downloaded at runtime and must never be
# embedded in the release bundle again.
[[ ! -e "$app_path/Contents/Resources/AgentCleanup/node" ]] || {
    echo "Release bundle must not embed a Node.js runtime" >&2
    exit 1
}

plutil -lint "$info_plist" "$helper_plist" "$legacy_helper_plist" "$privacy_manifest"

bundle_identifier=$(plutil -extract CFBundleIdentifier raw "$info_plist")
[[ "$bundle_identifier" == "com.jianyintang.FindDiskKiller" ]] || {
    echo "Unexpected bundle identifier: $bundle_identifier" >&2
    exit 1
}

sparkle_feed=$(plutil -extract SUFeedURL raw "$info_plist")
[[ "$sparkle_feed" == \
    "https://github.com/jianyintang/find-disk-killer/releases/latest/download/appcast.xml" ]] || {
    echo "Unexpected Sparkle feed URL: $sparkle_feed" >&2
    exit 1
}
sparkle_public_key=$(plutil -extract SUPublicEDKey raw "$info_plist")
if ! sparkle_key_length=$(printf '%s' "$sparkle_public_key" \
    | /usr/bin/base64 -D 2>/dev/null \
    | wc -c \
    | tr -d ' '); then
    sparkle_key_length=0
fi
[[ "$sparkle_key_length" == "32" ]] || {
    echo "Release App is missing a valid Sparkle Ed25519 public key" >&2
    exit 1
}
[[ "$(plutil -extract SURequireSignedFeed raw "$info_plist")" == "true" ]] || {
    echo "Release App must require a signed Sparkle feed" >&2
    exit 1
}
[[ "$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$info_plist")" == "true" \
    && "$(plutil -extract SUEnableSystemProfiling raw "$info_plist")" == "false" \
    && "$(plutil -extract SUEnableAutomaticChecks raw "$info_plist")" == "true" \
    && "$(plutil -extract SUAutomaticallyUpdate raw "$info_plist")" == "false" \
    && "$(plutil -extract SUAllowsAutomaticUpdates raw "$info_plist")" == "false" \
    && "$(plutil -extract SUScheduledCheckInterval raw "$info_plist")" == "86400" ]] || {
    echo "Release App has unsafe or unexpected Sparkle scheduling/profile settings" >&2
    exit 1
}

privacy_tracking=$(plutil -extract NSPrivacyTracking raw "$privacy_manifest")
[[ "$privacy_tracking" == "false" ]] || {
    echo "Privacy manifest must declare tracking as disabled" >&2
    exit 1
}

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --verify --strict --verbose=2 "$helper"
codesign --verify --strict --verbose=2 "$claude_cleanup_helper"

app_signature=$(codesign -dvvv "$app_path" 2>&1)
helper_signature=$(codesign -dvvv "$helper" 2>&1)
claude_cleanup_helper_signature=$(codesign -dvvv "$claude_cleanup_helper" 2>&1)
team_identifier=$(awk -F= '/^TeamIdentifier=/{print $2}' <<<"$app_signature")
[[ "$team_identifier" == "Y3A8BJ4475" ]] || {
    echo "Unexpected signing team: ${team_identifier:-missing}" >&2
    exit 1
}
for signature in \
    "$app_signature" \
    "$helper_signature" \
    "$claude_cleanup_helper_signature"; do
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

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/find-disk-killer-verify.XXXXXX")
cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

decoded_profile="$temporary_directory/developer-id-profile.plist"
security cms -D -i "$provisioning_profile" > "$decoded_profile"
profile_application_identifier=$(plutil \
    -extract 'Entitlements.com\.apple\.application-identifier' raw \
    "$decoded_profile")
profile_team_identifier=$(plutil -extract TeamIdentifier.0 raw "$decoded_profile")
profile_all_devices=$(plutil -extract ProvisionsAllDevices raw "$decoded_profile")
[[ "$profile_application_identifier" == \
    "Y3A8BJ4475.com.jianyintang.FindDiskKiller" \
    && "$profile_team_identifier" == "Y3A8BJ4475" \
    && "$profile_all_devices" == "true" ]] || {
    echo "App does not contain the expected Developer ID provisioning profile" >&2
    exit 1
}

read_entitlements() {
    local signed_path=$1
    local output_path=$2
    codesign -d --entitlements "$output_path" --xml "$signed_path"
}

require_empty_entitlements() {
    local signed_path=$1
    local output_path=$2
    read_entitlements "$signed_path" "$output_path"
    [[ "$(plutil -convert json -o - "$output_path")" == "{}" ]] || {
        echo "Release signing entitlements changed for $signed_path" >&2
        plutil -p "$output_path" >&2
        exit 1
    }
}

app_entitlements="$temporary_directory/app-entitlements.plist"
read_entitlements "$app_path" "$app_entitlements"
app_application_identifier=$(plutil \
    -extract 'com\.apple\.application-identifier' raw \
    "$app_entitlements")
app_team_identifier=$(plutil \
    -extract 'com\.apple\.developer\.team-identifier' raw \
    "$app_entitlements")
[[ "$app_application_identifier" == \
    "Y3A8BJ4475.com.jianyintang.FindDiskKiller" \
    && "$app_team_identifier" == "Y3A8BJ4475" ]] || {
    echo "App is missing its ServiceManagement signing identity" >&2
    plutil -p "$app_entitlements" >&2
    exit 1
}
plutil -remove 'com\.apple\.application-identifier' "$app_entitlements"
plutil -remove 'com\.apple\.developer\.team-identifier' "$app_entitlements"
[[ "$(plutil -convert json -o - "$app_entitlements")" == "{}" ]] || {
    echo "App has unexpected release entitlements" >&2
    plutil -p "$app_entitlements" >&2
    exit 1
}
helper_entitlements="$temporary_directory/helper-entitlements.plist"
read_entitlements "$helper" "$helper_entitlements"
helper_application_identifier=$(plutil \
    -extract 'com\.apple\.application-identifier' raw \
    "$helper_entitlements")
[[ "$helper_application_identifier" == \
    "Y3A8BJ4475.com.jianyintang.FindDiskKiller.TraceHelper.v2" ]] || {
    echo "Trace helper is missing its system-service application identifier" >&2
    plutil -p "$helper_entitlements" >&2
    exit 1
}
plutil -remove 'com\.apple\.application-identifier' "$helper_entitlements"
[[ "$(plutil -convert json -o - "$helper_entitlements")" == "{}" ]] || {
    echo "Trace helper has unexpected release entitlements" >&2
    plutil -p "$helper_entitlements" >&2
    exit 1
}
claude_cleanup_helper_entitlements="$temporary_directory/claude-cleanup-helper-entitlements.plist"
read_entitlements "$claude_cleanup_helper" "$claude_cleanup_helper_entitlements"
claude_cleanup_helper_application_identifier=$(plutil \
    -extract 'com\.apple\.application-identifier' raw \
    "$claude_cleanup_helper_entitlements")
[[ "$claude_cleanup_helper_application_identifier" == \
    "Y3A8BJ4475.com.jianyintang.FindDiskKiller.ClaudeCleanupHelper" ]] || {
    echo "Claude cleanup helper has an unexpected application identifier" >&2
    plutil -p "$claude_cleanup_helper_entitlements" >&2
    exit 1
}
plutil -remove 'com\.apple\.application-identifier' \
    "$claude_cleanup_helper_entitlements"
[[ "$(plutil -convert json -o - "$claude_cleanup_helper_entitlements")" == "{}" ]] || {
    echo "Claude cleanup helper has unexpected release entitlements" >&2
    plutil -p "$claude_cleanup_helper_entitlements" >&2
    exit 1
}

helper_program=$(plutil -extract BundleProgram raw "$helper_plist")
[[ "$helper_program" == \
    "Contents/Library/LaunchDaemons/com.jianyintang.FindDiskKiller.TraceHelper" ]] || {
    echo "Unexpected trace helper BundleProgram: $helper_program" >&2
    exit 1
}
mach_service_enabled=$(plutil \
    -extract 'MachServices.com\.jianyintang\.FindDiskKiller\.TraceHelper\.v2' raw \
    "$helper_plist")
[[ "$mach_service_enabled" == "true" ]] || {
    echo "Trace helper Mach service is not enabled" >&2
    exit 1
}

legacy_label=$(plutil -extract Label raw "$legacy_helper_plist")
[[ "$legacy_label" == "com.jianyintang.FindDiskKiller.TraceHelper" ]] || {
    echo "Legacy trace helper migration plist has an unexpected label" >&2
    exit 1
}

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
require_universal_binary "$claude_cleanup_helper"

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
