#!/usr/bin/env bash

set -euo pipefail

app_path=${1:-/Applications/FindDiskKiller.app}
expected_version=${EXPECTED_VERSION:-}
expected_build=${EXPECTED_BUILD:-}
service_label=com.jianyintang.FindDiskKiller.TraceHelper

[[ "$app_path" == /Applications/*.app ]] || {
    echo "The installed helper test only accepts an app in /Applications" >&2
    exit 64
}
[[ -d "$app_path" ]] || {
    echo "Installed app not found: $app_path" >&2
    exit 66
}

info_plist="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/FindDiskKiller"
helper="$app_path/Contents/Library/LaunchDaemons/$service_label"
version=$(plutil -extract CFBundleShortVersionString raw "$info_plist")
build=$(plutil -extract CFBundleVersion raw "$info_plist")

if [[ -n "$expected_version" && "$version" != "$expected_version" ]]; then
    echo "Expected version $expected_version, found $version" >&2
    exit 1
fi
if [[ -n "$expected_build" && "$build" != "$expected_build" ]]; then
    echo "Expected build $expected_build, found $build" >&2
    exit 1
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/find-disk-killer-smoke.XXXXXX")
cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

helper_entitlements="$temporary_directory/helper-entitlements.plist"
codesign --verify --deep --strict "$app_path"
codesign -d --entitlements "$helper_entitlements" --xml "$helper"
application_identifier=$(plutil \
    -extract 'com\.apple\.application-identifier' raw \
    "$helper_entitlements")
[[ "$application_identifier" == \
    "Y3A8BJ4475.com.jianyintang.FindDiskKiller.TraceHelper" ]] || {
    echo "Installed trace helper has an invalid application identifier" >&2
    exit 1
}

test_started_at=$(date -u '+%Y-%m-%d %H:%M:%S')
smoke_output="$temporary_directory/smoke-output.txt"
"$executable" --authorize-and-test-trace-helper 2>&1 | tee "$smoke_output"
grep -Fq 'trace-helper-smoke=success' "$smoke_output" || {
    echo "Trace helper smoke test did not report success" >&2
    exit 1
}

launch_state="$temporary_directory/launch-state.txt"
launchctl print "system/$service_label" > "$launch_state"
grep -Eq 'state = running|active count = [1-9]' "$launch_state" || {
    echo "Trace helper is not running after the smoke test" >&2
    cat "$launch_state" >&2
    exit 1
}

constraint_log="$temporary_directory/constraint-log.txt"
/usr/bin/log show \
    --start "$test_started_at" \
    --style compact \
    --predicate "eventMessage CONTAINS[c] '$service_label' AND eventMessage CONTAINS[c] 'Launch Constraint Violation'" \
    > "$constraint_log"
if grep -Fq 'Launch Constraint Violation' "$constraint_log"; then
    echo "A launch constraint violation occurred during the smoke test" >&2
    cat "$constraint_log" >&2
    exit 1
fi

echo "Verified installed tracing helper for FindDiskKiller $version ($build)"
