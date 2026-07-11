#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cleanzip-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

target="$(uname -m)-apple-macos14.0"

xcrun swiftc -Onone -parse-as-library -DCLEANZIP_TESTING \
  -target "$target" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework UniformTypeIdentifiers \
  -framework UserNotifications \
  "$ROOT/src/main.swift" \
  "$ROOT/tests/TableBehaviorTests.swift" \
  -o "$BUILD_DIR/TableBehaviorTests"

CLEANZIP_7ZZ_PATH="$ROOT/src/Resources/7zz" "$BUILD_DIR/TableBehaviorTests"
