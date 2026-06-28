# CleanZip

CleanZip is a lightweight native macOS 26 archive utility focused on clean ZIP creation, common archive extraction, archive previews, and split archive creation.

## Features

- Finder service: one entry for compressing or extracting selected items.
- Clean ZIP output: excludes `.DS_Store`, `__MACOSX/`, and AppleDouble `._*` files.
- Archive preview: lists file names, sizes, modified times, and directory structure.
- Extraction support through system tools and bundled `7zz`.
- Split archive creation for ZIP and 7Z.
- macOS 26 Liquid Glass app icon built from vector SVG layers and compiled to `Assets.car` on GitHub Actions.

## Repository Layout

- `work/CleanZipBuild/src/main.swift`: main AppKit/SwiftUI app.
- `work/CleanZipBuild/src/service.swift`: Finder service helper.
- `work/CleanZipBuild/src/build.sh`: local Swift build script.
- `work/CleanZipBuild/src/generate_filled_icon.py`: vector icon generator and `Assets.car` compiler when Xcode `actool` is available.
- `.github/workflows/cleanzip-liquid-glass-icon.yml`: macOS 26 GitHub Actions build that compiles the dynamic icon stack.

## Build

Local build with Command Line Tools:

```sh
work/CleanZipBuild/src/build.sh
```

Dynamic Liquid Glass icon compilation requires Xcode 26 `actool`. If full Xcode is not installed locally, run the GitHub Actions workflow:

```sh
gh workflow run cleanzip-liquid-glass-icon.yml --repo lyc280705/CleanZip --ref main
```

The workflow uploads `CleanZip.app`, `CleanZipService.service`, the vector `AppIcon.icon` document, and an `Assets.car` inspection report.

## Install

Download `CleanZip.pkg` from the latest GitHub Release and open it. The installer places:

- `CleanZip.app` in `/Applications`
- `CleanZipService.service` in `/Library/Services`

The package is ad-hoc signed for local distribution, but it is not notarized with an Apple Developer ID.

Manual archive users can download `CleanZip.zip`, unzip it, move `CleanZip.app` to `/Applications`, and move `CleanZipService.service` to `/Library/Services`.

## Package

After building the app and service, create release artifacts:

```sh
work/CleanZipBuild/src/package.sh
```

## License

CleanZip source code is released under the MIT License. Bundled 7-Zip/`7zz` files are distributed under their own upstream license; see `7-Zip-License.txt` and `7-Zip-readme.txt` in the app resources.
