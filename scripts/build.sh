#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcode_dir="${PRESS_XCODE_DIR:-/Applications/Xcode.app/Contents/Developer}"
./scripts/prepare-runtime.sh
mkdir -p .build
staging="$(mktemp -d "$PWD/.build/.staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Press.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
options=(-swift-version 6 -sdk "$(xcrun --sdk macosx --show-sdk-path)"
    -target "$(uname -m)-apple-macosx27.0" -g
    -plugin-path "$xcode_dir/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins")
if [ "${CONFIGURATION:-Debug}" = Release ]; then options+=(-O); else options+=(-Onone); fi
xcrun swiftc "${options[@]}" -parse-as-library -module-name Press \
    Sources/Press/*.swift -o "$app/Contents/MacOS/Press"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/ArchiveFormats.json "$app/Contents/Resources/"
xcrun swift scripts/register-formats.swift Resources/ArchiveFormats.json "$app/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp .build/7zip/7zz "$app/Contents/MacOS/7zz"
cp .build/7zip/License.txt "$app/Contents/Resources/7-Zip-License.txt"
"$xcode_dir/usr/bin/actool" Artwork/Press.icon \
    --compile "$app/Contents/Resources" \
    --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist "$staging/icon-info.plist" \
    --app-icon Press --include-all-app-icons \
    --enable-on-demand-resources NO --development-region en \
    --target-device mac --minimum-deployment-target 27.0 --platform macosx
python3 scripts/sign.py "$app"
destination="$PWD/.build/Press.app"
if [ -d "$destination" ]; then mv "$destination" "$staging/previous.app"; fi
if ! mv "$app" "$destination"; then
    if [ -d "$staging/previous.app" ]; then mv "$staging/previous.app" "$destination"; fi
    exit 1
fi
printf 'Built %s\n' "$destination"
