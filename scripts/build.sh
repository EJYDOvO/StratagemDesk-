#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodebuild -project StratagemDesk.xcodeproj -scheme StratagemDesk \
  -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath build/DerivedData ARCHS=arm64 build > build/release-build.log 2>&1
mkdir -p build/Release
ditto build/DerivedData/Build/Products/Release/StratagemDeskPublic.app build/Release/StratagemDeskPublic.app
printf 'Built: %s/build/Release/StratagemDeskPublic.app\n' "$PWD"
