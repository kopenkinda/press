# Third-party notices

Press bundles the unmodified 7-Zip 26.03 macOS console executable, then signs it
with the local development certificate. Copyright 1999-2026 Igor Pavlov.

7-Zip is distributed under the GNU LGPL, with BSD-licensed portions and the
unRAR restriction. The complete upstream license accompanies the executable
in `Contents/Resources/7-Zip-License.txt` inside Press.app.

Binary: https://www.7-zip.org/a/7z2603-mac.tar.xz

Corresponding source: https://github.com/ip7z/7zip/tree/26.03

Source download: https://github.com/ip7z/7zip/releases/download/26.03/7z2603-src.tar.xz

The build script verifies the downloaded archive's SHA-256 before extraction.
Press uses 7-Zip only to extract archives. It does not create RAR archives.
