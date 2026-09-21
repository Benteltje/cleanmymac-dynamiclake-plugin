#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
build_dir="$repo_dir/build"
dist_dir="$repo_dir/dist"
package_name="CleanMyMac.dynamiclakeplugin"
package_dir="$build_dir/$package_name"
version=$(/usr/bin/plutil -extract version raw -- "$repo_dir/plugin.json")

/bin/rm -rf "$build_dir" "$dist_dir"
/bin/mkdir -p "$package_dir/Assets" "$dist_dir"

sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
for architecture in arm64 x86_64; do
    /usr/bin/xcrun swiftc \
        -parse-as-library \
        -O \
        -target "$architecture-apple-macos12.0" \
        -sdk "$sdk_path" \
        "$repo_dir/Sources/CleanMyMacPlugin.swift" \
        -o "$build_dir/cleanmymac-monitor-$architecture"
done

/usr/bin/lipo -create \
    "$build_dir/cleanmymac-monitor-arm64" \
    "$build_dir/cleanmymac-monitor-x86_64" \
    -output "$package_dir/cleanmymac-monitor"
/bin/chmod 755 "$package_dir/cleanmymac-monitor"

/bin/cp "$repo_dir/plugin.json" "$repo_dir/CleanMyMacIcon.png" "$repo_dir/LICENSE" \
    "$repo_dir/THIRD_PARTY_NOTICES.md" "$package_dir/"
/bin/cp "$repo_dir"/Assets/*.png "$package_dir/Assets/"

archive="$dist_dir/CleanMyMac-$version.dynamiclakeplugin.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package_dir" "$archive"

echo "Built $package_dir"
echo "Archive $archive"
/usr/bin/file "$package_dir/cleanmymac-monitor"
/usr/bin/du -h "$archive"
