#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
"$repo_dir/scripts/build.sh"

package_dir="$repo_dir/build/CleanMyMac.dynamiclakeplugin"
binary="$package_dir/cleanmymac-monitor"

/usr/bin/jq -e . "$package_dir/plugin.json" >/dev/null
"$binary" --self-test

payload=$(DYNAMICLAKE_SETTING_COMPACT_PRESENTATION="Module name" "$binary" --demo-json)
echo "$payload" | /usr/bin/jq -e '.surfaces.compactLiveActivity.leftSlot.text == "Smart Care"' >/dev/null
echo "$payload" | /usr/bin/jq -e '.surfaces.sneakPeek.leftSlot.source == "inlineData"' >/dev/null
echo "$payload" | /usr/bin/jq -e '.surfaces.sneakPeek.leftSlot.mimeType == "image/png"' >/dev/null

icon_payload=$(DYNAMICLAKE_SETTING_COMPACT_PRESENTATION="Module icon" "$binary" --demo-json)
echo "$icon_payload" | /usr/bin/jq -e '.surfaces.compactLiveActivity.leftSlot.source == "inlineData"' >/dev/null
echo "$icon_payload" | /usr/bin/jq -e '.surfaces.compactLiveActivity.leftSlot.mimeType == "image/png"' >/dev/null
echo "$icon_payload" | /usr/bin/jq -e '.surfaces.compactLiveActivity.leftSlot.base64Data | length > 0' >/dev/null
echo "$icon_payload" | /usr/bin/jq -e '.surfaces.sneakPeek.leftSlot.source == "sfSymbol"' >/dev/null
echo "$icon_payload" | /usr/bin/jq -e '.size == "small"' >/dev/null
echo "$icon_payload" | /usr/bin/jq -e '.surfaces.compactLiveActivity.rightSlot.value > 0.419 and .surfaces.compactLiveActivity.rightSlot.value < 0.421' >/dev/null

for asset in "$package_dir"/Assets/*.png; do
    size=$(/usr/bin/stat -f '%z' "$asset")
    if (( size > 49152 )); then
        echo "Asset exceeds DynamicLake's 48 KiB decoded-image limit: $asset ($size bytes)" >&2
        exit 1
    fi
done

frame_size=$(printf '%s' "$payload" | /usr/bin/wc -c | /usr/bin/tr -d ' ')
if (( frame_size > 65536 )); then
    echo "Demo frame exceeds DynamicLake's 64 KiB limit ($frame_size bytes)" >&2
    exit 1
fi
icon_frame_size=$(printf '%s' "$icon_payload" | /usr/bin/wc -c | /usr/bin/tr -d ' ')
if (( icon_frame_size > 65536 )); then
    echo "Icon demo frame exceeds DynamicLake's 64 KiB limit ($icon_frame_size bytes)" >&2
    exit 1
fi

architectures=$(/usr/bin/lipo -archs "$binary")
[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]]

echo "All tests passed (universal binary, settings payloads, 8 module mappings, asset and frame limits)."
