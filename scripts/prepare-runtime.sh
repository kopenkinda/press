#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
expected=5ca87677072c59f5602e5c49baa27d4694bacd2259b4e507f0094249d4281480
mkdir -p .build
archive="$PWD/.build/7zip.tar.xz"
if [ ! -f "$archive" ]; then
    curl --fail --location --retry 2 https://www.7-zip.org/a/7z2603-mac.tar.xz -o "$archive.download"
    mv "$archive.download" "$archive"
fi
actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
if [ "$actual" != "$expected" ]; then
    echo '7-Zip checksum mismatch. Remove .build/7zip.tar.xz and rebuild.' >&2
    exit 1
fi
mkdir -p .build/7zip
tar -xf "$archive" -C .build/7zip
