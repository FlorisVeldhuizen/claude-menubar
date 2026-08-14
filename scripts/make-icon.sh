#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SET="$ROOT/build/AppIcon.iconset"

rm -rf "$SET"
swift "$ROOT/scripts/make-icon.swift" "$SET" > /dev/null
mkdir -p "$ROOT/Resources"
iconutil --convert icns "$SET" --output "$ROOT/Resources/AppIcon.icns"
echo "Wrote $ROOT/Resources/AppIcon.icns"
