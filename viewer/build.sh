#!/bin/zsh
# Build "Pixel Live.app" with the Command Line Tools (no Xcode needed) and
# install it in /Applications. Usage: ./build.sh [--no-install]
set -euo pipefail
cd "${0:A:h}"

APP="Pixel Live"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
BUNDLE="$OUT/$APP.app"
mkdir -p "$BUNDLE/Contents/MacOS"

# SDK 26.5: the macOS 27 SDK turns @State into a macro whose plugin ships only with Xcode.
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
# Keep compiler caches inside the workspace, including in restricted sandboxes.
mkdir -p .tmp/ModuleCache
swiftc -O -parse-as-library -swift-version 5 -sdk "$SDK" \
  -module-cache-path "$PWD/.tmp/ModuleCache" \
  -target arm64-apple-macos26.0 \
  -o "$BUNDLE/Contents/MacOS/PixelLive" \
  Sources/*.swift

cp Info.plist "$BUNDLE/Contents/Info.plist"
codesign --force -s - "$BUNDLE" >/dev/null

if [[ "${1:-}" == "--no-install" ]]; then
  rm -rf "build/$APP.app"; mkdir -p build; ditto "$BUNDLE" "build/$APP.app"
  echo "build/$APP.app"
else
  rm -rf "/Applications/$APP.app"; ditto "$BUNDLE" "/Applications/$APP.app"
  echo "/Applications/$APP.app"
fi
