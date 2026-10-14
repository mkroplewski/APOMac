#!/bin/zsh
# Builds APOMac.app and, optionally, a drag-to-install DMG.
#
#   ./scripts/package-app.sh                 # .build/app-bundle/APOMac.app
#   MAKE_DMG=1 ./scripts/package-app.sh      # ... plus APOMac-<version>.dmg
#
# Environment:
#   VERSION            Marketing version (default: latest git tag without "v", else 0.0.0-dev)
#   BUILD_NUMBER       Bundle build number (default: git commit count)
#   UNIVERSAL=1        Build for Apple silicon and Intel (default: host architecture only)
#   CONFIGURATION      release (default) or debug
#   CODESIGN_IDENTITY  "Developer ID Application: …" to sign for distribution (default: ad-hoc)
#   NOTARY_PROFILE     notarytool keychain profile; when set with MAKE_DMG=1 the DMG is notarized and stapled
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
product_name="APOMac"
binary_name="APOMacApp"
build_root="$project_root/.build/app-bundle"
app_bundle="$build_root/$product_name.app"

git_version="$(git -C "$project_root" describe --tags --abbrev=0 2>/dev/null || true)"
version="${VERSION:-${git_version#v}}"
version="${version:-0.0.0-dev}"
build_number="${BUILD_NUMBER:-$(git -C "$project_root" rev-list --count HEAD 2>/dev/null || echo 1)}"

arch_flags=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    arch_flags=(--arch arm64 --arch x86_64)
fi
swift build --package-path "$project_root" -c "$configuration" "${arch_flags[@]}"
binary="$(swift build --package-path "$project_root" -c "$configuration" "${arch_flags[@]}" --show-bin-path)/$binary_name"

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary" "$app_bundle/Contents/MacOS/$product_name"
cp "$project_root/packaging/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$project_root/packaging/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"
cp "$project_root/LICENSE" "$project_root/NOTICE.md" "$app_bundle/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$app_bundle"
else
    codesign --force --sign - "$app_bundle"
fi
codesign --verify --strict "$app_bundle"
echo "Created $app_bundle ($version, build $build_number, $(lipo -archs "$app_bundle/Contents/MacOS/$product_name"))"

if [[ "${MAKE_DMG:-0}" == "1" ]]; then
    dmg_path="${DMG_PATH:-$build_root/$product_name-$version.dmg}"
    staging="$build_root/dmg"
    rm -rf "$staging" "$dmg_path"
    mkdir -p "$staging"
    cp -R "$app_bundle" "$staging/"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname "$product_name $version" -srcfolder "$staging" -ov -format UDZO -fs HFS+ "$dmg_path" >/dev/null
    rm -rf "$staging"
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$dmg_path"
    fi
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$dmg_path"
    fi
    echo "Created $dmg_path"
fi
