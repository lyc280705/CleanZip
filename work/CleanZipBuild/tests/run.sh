#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cleanzip-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

target="$(uname -m)-apple-macos14.0"
SDK="${CLEANZIP_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"

xcrun swiftc -Onone -parse-as-library -swift-version 6 -strict-concurrency=complete -warn-concurrency -DCLEANZIP_TESTING \
  -target "$target" -sdk "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework UniformTypeIdentifiers \
  -framework UserNotifications \
  "$ROOT/src/main.swift" \
  "$ROOT/src/ArchiveFileSafety.swift" \
  "$ROOT/tests/TableBehaviorTests.swift" \
  "$ROOT/tests/ArchiveSafetyTests.swift" \
  -o "$BUILD_DIR/TableBehaviorTests"

CLEANZIP_7ZZ_PATH="$ROOT/src/Resources/7zz" "$BUILD_DIR/TableBehaviorTests"

xcrun swiftc -Onone -parse-as-library -swift-version 6 -strict-concurrency=complete -warn-concurrency \
  -DCLEANZIP_TESTING -DCLEANZIP_SERVICE_TESTING -target "$target" -sdk "$SDK" \
  -framework AppKit -framework UserNotifications \
  "$ROOT/src/service.swift" "$ROOT/src/ArchiveFileSafety.swift" \
  "$ROOT/tests/ArchiveSafetyTests.swift" "$ROOT/tests/ServiceBehaviorTests.swift" \
  -o "$BUILD_DIR/ServiceBehaviorTests"

CLEANZIP_7ZZ_PATH="$ROOT/src/Resources/7zz" "$BUILD_DIR/ServiceBehaviorTests"
