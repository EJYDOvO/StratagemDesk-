#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swift build --scratch-path build/spm > build/swift-build.log 2>&1
STRATAGEM_TEST_HOST="$PWD/build/spm/debug/StratagemDesk" \
  swift test --scratch-path build/spm 2>&1 | tee build/swift-test.log
