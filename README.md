# Press

A small native SwiftUI and AppKit unarchiver for macOS 27. Preview the archive and container formats read by bundled 7-Zip, then choose
where to extract them. This includes RAR, ZIP/ZIPX, 7z, TAR, GZIP, BZIP2, XZ,
Zstandard, CAB, ISO, and DMG. No account, activation,
archive creation, or background service.

## Use

Drop archives into the window, open them with Command-O, or use Finder's
Open With > Press. Each archive opens in its own native
macOS tab. By default, opening an archive only reads its file listing. It does
not write the files inside to disk. Compressed TAR files stream through the
decoder to show their inner folder tree without saving an intermediate TAR.
Other nested archives remain files in the preview.

The preview shows an expandable folder tree, with files inside their folders
and sizes beside them. Use the disclosure arrows or keyboard arrow keys to
explore. Folders appear even when the archive only stores file paths. The
compressed and reported expanded sizes appear above the tree.

Select a single file and press Space, or use its Quick Look context menu, to
preview it in macOS's native Quick Look panel. Space or Escape closes the panel.
Only that file is written into a private temporary folder. Solid archives and
compressed TAR files may still require decoding other data to reach it. A
preview is limited to 100 MB and 60 seconds and uses the same password flow
and sandbox as extraction. Formats Quick Look cannot render show its normal
file information instead.

The temporary file remains available for Quick Look's Open With action until
the next file preview, archive reload, tab closure, or app quit. Changes to a
temporary copy do not update the archive.

Click Extract, then choose a destination folder. Press creates
a new folder named after the archive there. If that name exists, Press adds a
number. Original archives and existing destination files remain untouched.

Encrypted headers ask for a password before showing the listing. Archives
with visible headers can be previewed without a password and ask when you
extract. A wrong password lets you retry or cancel. Each tab keeps its password
in memory until closed and sends it to the helper through standard input.
Passwords are not saved or shared between tabs.

Command-T opens an empty tab, Command-W closes the current tab, and Command-R
reloads its preview. Closing a tab or quitting cancels its operation and removes
its temporary folder. After extraction, Show in Finder reveals the result.

## Settings

Open Press > Settings with Command-comma. The General and File Types tabs use
native macOS toolbar tabs.

General has independent settings for opening archives through Finder or Open,
and for dropping archives into a Press window. Each setting offers:

- Preview in Press, the default.
- Extract Beside the Archive, into a new folder named after the archive.
- Choose Where to Extract, which opens the destination chooser.

Both settings default to Preview in Press. Existing opening preferences are
preserved when upgrading; the new drop setting starts with preview. You can
use Extract Beside the Archive for Finder and Preview in Press for drops.

Extract Beside the Archive runs without opening an archive window. An encrypted
archive shows a standalone password dialog; failures show an alert. Multiple
archives are processed in sequence. Each finished folder is revealed in Finder.
Press exits when these jobs finish if no
browser or Settings window is open. Existing windows remain open, and launching
Press itself still opens its normal drop window.

All modes inspect the archive first and enforce the same extraction limits.
Changing a setting affects newly opened archives. Reloading an existing
preview never triggers automatic extraction.

File Types lists the registered extensions with their current default apps.
Search by format or extension. Click Use Press
beside a format to request the association through macOS. The system may ask
for confirmation. Opening Settings or installing an update does not explicitly
request any default-app changes.

## Build and run

Requires macOS 27, Xcode 27, Python 3, and OpenSSL. Open Xcode once and accept
its license, then run:

```sh
./scripts/run.sh
```

This builds, signs, installs `/Applications/Press.app`, and launches it.
`./scripts/build.sh` builds and signs `.build/Press.app` without installing.
Set `CONFIGURATION=Release` for an optimized build. `DEVELOPER_DIR` chooses
the compiler; `PRESS_XCODE_DIR` can select another Xcode installation for
icon compilation and SwiftUI compiler plugins.

The first build downloads the official 7-Zip 26.03 macOS console executable
and checks its pinned SHA-256. Later builds reuse the download. The app runs
offline and bundles the helper and its license.

`Artwork/Press.icon` is an Icon Composer asset with four symmetric outward
arrows in one rounded SVG layer. It follows Blah's monochrome light, dark,
and tinted appearances. Xcode's asset compiler produces the app icon during the build.

Development signing follows Menu Dot and Blah. The first build creates a
persistent self-signed certificate in a private keychain under
`~/Library/Application Support/Press/Signing`. Later builds reuse it, sign
both the helper and app, and verify the bundle. Keep that directory private.
The scripts restore the keychain search list and do not change certificate
trust or the default keychain. This is local development signing, not
Developer ID signing or notarization.

## Code

- `PressApp.swift` owns native window tabs, Finder opening, and menus.
- `ContentView.swift` owns the file list, drop area, and password sheet.
- `ArchiveViewController.swift` connects each window to macOS Quick Look.
- `ArchiveModel.swift` owns one archive's preview and extraction state.
- `SettingsWindow.swift` owns opening preferences and file association actions.
- `Extractor.swift` lists archives, applies limits, and publishes completed folders.
- `ArchiveFormats.swift` reads the shared format catalogue and names output folders.

`Resources/ArchiveFormats.json` lists the bundled engine's archive and container
readers. The build uses it for Finder registration, and Settings uses it for
file associations. Checksums are excluded because they contain no files to
extract. The Open dialog also accepts unlisted extensions so 7-Zip can detect
the contents. Registration does not force Press to become the default app.

Listing runs with file writes denied except for a temporary metadata log.
Extraction runs with writes restricted to its private temporary directory in
the chosen destination. Both operations have network access denied. Press
rejects unsafe paths, symbolic links, and special files. It publishes successful
extractions with an exclusive rename so existing folders cannot be replaced.

## Prototype limits

Press permits up to 10 GB expanded and 10,000 entries per archive. A listing
has a 16 MB output limit and a 60-second timeout. Missing expanded sizes
appear as unknown; extraction still monitors actual output. Ambiguous listings
are rejected. Compressed TAR streams have a separate 10 GB decoded-byte limit.
Their common compound extensions and aliases select this streaming behavior. An archive whose file size or modification
time changes after preview must be reloaded before extraction.

Header sizes are untrusted. During extraction, Press checks the output's
logical size and entry count every 200 ms and checks again before publishing.
Crossing a limit stops the helper and deletes that operation's output.
Polling can overshoot a limit between checks. These safeguards reduce disk
exhaustion risk; they are not a hard disk quota or complete protection against
malicious archives. The prototype does not impose a helper memory limit.

Extraction always includes the whole archive. For multipart RAR, open the first `.rar` volume
and keep all parts together. Support for specific compression methods follows
the bundled 7-Zip version.

The helper's write restrictions use macOS `sandbox-exec`, a deprecated system
tool available on the development machine's macOS 27 build. Revisit that
boundary before distributing the app.

## Tests

Run `./scripts/test.sh` with the same Xcode and Python requirements as the app.
It prepares small local fixtures, then uses Swift Testing to exercise the real
7-Zip helper under the app's sandbox rules. It does not install Press, open UI,
or change file associations. Pass `--filter ModelTests` to run a subset.

The suite covers folder trees, ZIP/ZIPX, RAR, 7z, TAR and compressed TAR,
standalone compressed files, password prompts and retries, per-tab isolation,
opening and drop preferences, Quick Look file selection and cleanup,
cancellation, destination collisions, changed archives,
unsafe paths, links, size and entry limits, and Finder registration metadata.
Large logical-size checks use sparse files instead of allocating 10 GB.

Native window/tab interactions, Quick Look presentation, destination sheets,
macOS association consent, and icon appearance still need manual checks. The suite samples supported
formats and compression methods; it does not exercise every 7-Zip codec.
See [third-party notices](THIRD_PARTY_NOTICES.md) for the engine's license and source.
