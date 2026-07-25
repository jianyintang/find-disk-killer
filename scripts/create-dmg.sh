#!/usr/bin/env bash

set -euo pipefail

root_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_path=${1:-}
output_path=${2:-}
volume_name=${3:-FindDiskKiller}
template_dmg=${DMG_TEMPLATE:-}

[[ -d "$app_path" && "$app_path" == *.app ]] || {
    echo "Usage: create-dmg.sh <app-path> <output.dmg> [volume-name]" >&2
    exit 64
}
[[ -n "$output_path" && "$output_path" == *.dmg ]] || {
    echo "Usage: create-dmg.sh <app-path> <output.dmg> [volume-name]" >&2
    exit 64
}
[[ ! -e "$output_path" ]] || {
    echo "DMG output already exists: $output_path" >&2
    exit 1
}
if [[ -n "$template_dmg" && ! -f "$template_dmg" ]]; then
    echo "DMG template does not exist: $template_dmg" >&2
    exit 1
fi

for command_name in ditto hdiutil osascript xcrun; do
    command -v "$command_name" >/dev/null || {
        echo "Required command is unavailable: $command_name" >&2
        exit 1
    }
done

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/find-disk-killer-dmg.XXXXXX")
mount_point=""
cleanup() {
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        hdiutil detach -force "$mount_point" >/dev/null 2>&1 || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

staging_directory="$temporary_directory/staging"
background_directory="$staging_directory/.background"
read_write_dmg="$temporary_directory/installer-read-write.dmg"
app_name=$(basename "$app_path")

mkdir -p "$(dirname "$output_path")"
if [[ -n "$template_dmg" ]]; then
    hdiutil convert "$template_dmg" \
        -format UDRW \
        -o "$read_write_dmg" >/dev/null
else
    mkdir -p "$background_directory"
    ditto "$app_path" "$staging_directory/$app_name"
    ln -s /Applications "$staging_directory/Applications"
    xcrun swift "$root_directory/scripts/render-dmg-background.swift" \
        "$root_directory/scripts/assets/dmg-background-source.png" \
        "$background_directory/installer-background.png"

    hdiutil create \
        -volname "$volume_name" \
        -srcfolder "$staging_directory" \
        -fs HFS+ \
        -format UDRW \
        "$read_write_dmg" >/dev/null
fi

attach_output=$(hdiutil attach -nobrowse -readwrite "$read_write_dmg")
mount_point=$(awk -F '\t' 'END {print $NF}' <<<"$attach_output")
[[ -d "$mount_point" ]] || {
    echo "Unable to locate the mounted DMG volume." >&2
    exit 1
}

if [[ -n "$template_dmg" ]]; then
    installed_app="$mount_point/$app_name"
    [[ -d "$installed_app" ]] || {
        echo "DMG template does not contain $app_name" >&2
        exit 1
    }
    rm -rf "$installed_app"
    ditto "$app_path" "$installed_app"
else
    finder_error_path="$temporary_directory/finder-error.txt"
    if ! osascript - "$mount_point" "$app_name" 2>"$finder_error_path" <<'APPLESCRIPT'
on run arguments
    set mountPath to item 1 of arguments
    set appName to item 2 of arguments
    set mountedVolume to POSIX file mountPath as alias

    tell application "Finder"
        open mountedVolume
        delay 1

        set installerWindow to container window of mountedVolume
        set current view of installerWindow to icon view
        set toolbar visible of installerWindow to false
        set statusbar visible of installerWindow to false
        set pathbar visible of installerWindow to false
        set bounds of installerWindow to {120, 120, 780, 520}

        set iconOptions to icon view options of installerWindow
        set arrangement of iconOptions to not arranged
        set icon size of iconOptions to 96
        set text size of iconOptions to 13
        set label position of iconOptions to bottom
        set background picture of iconOptions to file ".background:installer-background.png" of mountedVolume

        set position of item appName of mountedVolume to {170, 235}
        set position of item "Applications" of mountedVolume to {490, 235}
        set extension hidden of item appName of mountedVolume to true

        update mountedVolume without registering applications
        delay 2
        close installerWindow
    end tell
end run
APPLESCRIPT
    then
        finder_error=$(<"$finder_error_path")
        if [[ "$finder_error" == *"-1743"* ]]; then
            echo "Finder automation permission is required to create the styled DMG." >&2
            echo "Set DMG_TEMPLATE to a previously approved installer DMG to build without Finder automation." >&2
        else
            echo "$finder_error" >&2
        fi
        exit 1
    fi
fi

sync
hdiutil detach "$mount_point" >/dev/null
mount_point=""

hdiutil convert "$read_write_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$output_path" >/dev/null

echo "Created DMG: $output_path"
