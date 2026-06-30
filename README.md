# CleanZip

<p align="center">
  <img src="work/CleanZipBuild/AppIconPreview.png" width="120" alt="CleanZip icon">
</p>

<p align="center">
  <strong>A lightweight native macOS 26 archive app for clean ZIPs, RAR/7Z extraction, quick previews, Finder right-click actions, and split archives.</strong>
</p>

<p align="center">
  <a href="https://github.com/lyc280705/CleanZip/releases/latest">Download latest release</a>
  ·
  <a href="https://github.com/lyc280705/CleanZip/releases/tag/v2.6.29">CleanZip 2.6.29</a>
  ·
  <a href="#build-from-source">Build from source</a>
</p>

<p align="center">
  <a href="https://github.com/lyc280705/CleanZip/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/lyc280705/CleanZip?label=download"></a>
  <img alt="macOS 26" src="https://img.shields.io/badge/macOS-26+-black">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-native-orange">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

CleanZip is built for the everyday archive jobs that should be fast and boring: create ZIP files that do not contain macOS metadata, remove `.DS_Store` noise before sharing, inspect an archive before extracting it, split large archives, and use one clear Finder action instead of a crowded context menu.

It is intentionally small: no always-on background app, no history database, no archive editor, and no heavy all-in-one file manager.

## Best For

- Sending ZIP files to Windows or Linux users without hidden macOS metadata.
- Quickly previewing ZIP, 7Z, RAR, TAR, and other archives before extracting them.
- Creating split ZIP or split 7Z archives for upload limits.
- Keeping Finder's right-click menu simple with one compress/extract action.
- Using a local-first archive utility that does not upload files or keep history.

## Screenshots

<p align="center">
  <img src="docs/images/archive-preview.png" alt="CleanZip archive preview window" width="860">
</p>

<p align="center">
  <em>Preview archive contents before extracting.</em>
</p>

<p align="center">
  <img src="docs/images/selected-items.png" alt="CleanZip selected items window" width="860">
</p>

<p align="center">
  <em>Manage selected files and folders, then create a clean archive.</em>
</p>

## Why CleanZip

- Clean by default: ZIP files exclude `.DS_Store`, `__MACOSX/`, and AppleDouble `._*` metadata, making them friendlier for Windows, Linux, and web upload workflows.
- Native macOS 26 UI: AppKit and SwiftUI window, native toolbar, native table previews, progress HUD, notifications, and Liquid Glass interface effects.
- One Finder action: select files, folders, or archives in Finder, then use `CleanZip Compress or Extract`.
- Preview before extracting: view file names, sizes, modified times, and folder structure without unpacking everything first.
- Split archives: create multi-part ZIP and 7Z archives for upload limits or transfer constraints.
- Lightweight by design: the Finder service launches only when used, and the main app quits when its window closes.

## Download

Download `CleanZip-2.6.29.pkg` from the [latest release](https://github.com/lyc280705/CleanZip/releases/latest). For most users, the `.pkg` installer is the easiest option.

The installer places:

- `CleanZip.app` in `/Applications`
- `CleanZipService.service` in `/Library/Services`

The package is ad-hoc signed for local distribution, but it is not notarized with an Apple Developer ID. If macOS blocks the first launch, use Finder's **Open** action from the context menu and confirm once.

Manual installation is also available from `CleanZip-2.6.29.zip`: move `CleanZip.app` to `/Applications` and `CleanZipService.service` to `/Library/Services`.

## Features

| Area | Details |
| --- | --- |
| Clean compression | Creates clean ZIP output and excludes `.DS_Store`, `__MACOSX/`, and `._*` metadata. |
| Finder integration | Adds one right-click service for compressing ordinary files/folders or extracting archives. |
| Archive preview | Lists archive contents with name, size, modified time, and folder structure. Includes search. |
| Extraction | Extracts common formats through bundled `7zz` and system tools. |
| Split archive creation | Supports split ZIP and split 7Z creation with common presets and custom sizes. |
| Progress | Shows progress for larger compression and extraction jobs in the app and lightweight service HUD. |
| Localization | Localized app UI, Finder service menu, notifications, errors, and document metadata. |

## Search Keywords

CleanZip is useful if you are looking for a macOS archive utility, clean ZIP creator, `.DS_Store` remover, Finder Quick Action compressor, RAR extractor, 7Z extractor, split ZIP creator, split 7Z creator, or lightweight Keka/BetterZip-style alternative focused on simple everyday archive workflows.

## Supported Formats

CleanZip can preview and extract common archive formats supported by bundled `7zz`, including:

- ZIP, 7Z, RAR
- TAR, TGZ, GZ, BZ2, XZ, ZST
- ISO, CAB, DMG, XAR
- JAR, WAR, APK
- split ZIP and split 7Z archives

CleanZip creates regular ZIP, split ZIP, regular 7Z, and split 7Z archives. It does not create RAR archives.

## Supported Languages

CleanZip follows the user's macOS language preferences and falls back to English when a preferred language is unavailable.

- English
- Simplified Chinese
- Traditional Chinese
- Japanese
- Korean
- French
- German
- Spanish
- Italian
- Brazilian Portuguese
- Russian

## Privacy

CleanZip runs locally on your Mac. Archive operations are performed with local system tools and the bundled `7zz` binary. It does not upload files, phone home, keep a history database, or run a permanent background service.

## Repository Layout

- `work/CleanZipBuild/src/main.swift`: main AppKit/SwiftUI app.
- `work/CleanZipBuild/src/service.swift`: Finder service helper.
- `work/CleanZipBuild/src/Resources/*.lproj`: localized app, service, and Info.plist resources.
- `work/CleanZipBuild/src/build.sh`: local Swift build script.
- `work/CleanZipBuild/src/package.sh`: package and ZIP release artifact script.
- `work/CleanZipBuild/src/generate_filled_icon.py`: vector icon generator and `Assets.car` compiler when Xcode `actool` is available.
- `.github/workflows/cleanzip-liquid-glass-icon.yml`: macOS 26 GitHub Actions build that compiles the dynamic icon stack and release package.

## Build From Source

Local build with Command Line Tools:

```sh
work/CleanZipBuild/src/build.sh
```

Dynamic Liquid Glass icon compilation requires Xcode 26 `actool`. If full Xcode is not installed locally, run the GitHub Actions workflow:

```sh
gh workflow run cleanzip-liquid-glass-icon.yml --repo lyc280705/CleanZip --ref main
```

Create release artifacts after building:

```sh
work/CleanZipBuild/src/package.sh
```

The workflow uploads `CleanZip.app`, `CleanZipService.service`, the vector `AppIcon.icon` document, release packages, and an `Assets.car` inspection report.

## License

CleanZip source code is released under the MIT License. Bundled 7-Zip/`7zz` files are distributed under their own upstream license; see `7-Zip-License.txt` and `7-Zip-readme.txt` in the app resources.
