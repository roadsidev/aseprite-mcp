#!/bin/zsh
# Deterministic renderer/model checks and a CPU-only frontier benchmark.
# Does not launch Pixel Live or create any windows.
set -euo pipefail
cd "${0:A:h}"
mkdir -p .tmp/ModuleCache
export TMPDIR="$PWD/.tmp"
sources=(Sources/*.swift)  # everything but the @main app entry
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swiftc -O -parse-as-library -swift-version 5 -sdk "$SDK" \
  -target arm64-apple-macos26.0 -module-cache-path "$PWD/.tmp/ModuleCache" \
  ${sources:#*/App.swift} Tests/RenderTests.swift -o .tmp/render-tests
.tmp/render-tests
