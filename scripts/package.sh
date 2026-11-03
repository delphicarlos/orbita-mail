#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p build evidence
swift build --configuration release > evidence/build-release.log 2>&1
binary_dir="$(swift build --configuration release --show-bin-path)"
bundle_dir="$project_dir/build/Órbita.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$binary_dir/OrbitaMail" "$bundle_dir/Contents/MacOS/OrbitaMail"
cp "$project_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
swift scripts/Icon.swift "$project_dir/build/AppIcon.iconset"
iconutil --convert icns "$project_dir/build/AppIcon.iconset" --output "$bundle_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$bundle_dir"
codesign --verify --strict "$bundle_dir"
ditto -c -k --sequesterRsrc --keepParent "$bundle_dir" "$project_dir/build/Orbita-Mac-arm64.zip"
printf '%s\n' "$bundle_dir"
