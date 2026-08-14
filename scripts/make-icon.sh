#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SET="$ROOT/build/AppIcon.iconset"

rm -rf "$SET"
# Compiled rather than interpreted, so the drawing can share the app's own crab.
swiftc -o "$ROOT/build/make-icon" \
    "$ROOT/Sources/ClaudeMenuBar/CrabIcon.swift" \
    "$ROOT/scripts/make-icon/main.swift"
"$ROOT/build/make-icon" "$SET" > /dev/null
mkdir -p "$ROOT/Resources"
iconutil --convert icns "$SET" --output "$ROOT/Resources/AppIcon.icns"
echo "Wrote $ROOT/Resources/AppIcon.icns"
