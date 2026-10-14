#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
product_name="APOMac"
binary_name="APOMacApp"
build_root="$project_root/.build/app-bundle"
app_bundle="$build_root/$product_name.app"

swift build --package-path "$project_root" -c "$configuration" --arch arm64
binary="$project_root/.build/arm64-apple-macosx/$configuration/$binary_name"

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary" "$app_bundle/Contents/MacOS/$product_name"
cp "$project_root/Sources/APOMacApp/Resources/AppInfo.plist" "$app_bundle/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $product_name" "$app_bundle/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$app_bundle/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$app_bundle/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.1.0" "$app_bundle/Contents/Info.plist" 2>/dev/null || true

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$app_bundle"
else
    codesign --force --deep --sign - "$app_bundle"
fi

echo "Created $app_bundle"

if [[ "${MAKE_DMG:-0}" == "1" ]]; then
    dmg_path="${DMG_PATH:-$build_root/$product_name.dmg}"
    hdiutil create -volname "$product_name" -srcfolder "$app_bundle" -ov -format UDZO "$dmg_path"
    echo "Created $dmg_path"
fi
