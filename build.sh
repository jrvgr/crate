#!/bin/sh
# Builds Crate.app from Crate.xcodeproj (needs Xcode 27.2 or later) into build/Crate.app.
#   ./build.sh        optimised (Release)
#   ./build.sh dev    unoptimised (Debug): quicker to build, slower at heavy work (cover dithering, scans)
# Xcode only recompiles what changed, so a rebuild after a small edit takes seconds.
#
# The version comes from git: the last tag (v0.2.0 → 0.2.0) and the number of commits as the build number;
# CI passes them from the tag it builds. Signs with the self-signed "Crate Local Signing" identity from the
# login keychain when it exists, so macOS keeps the app's privacy permissions (local network,
# network/removable volumes) across builds; ad hoc otherwise.
set -e
cd "$(dirname "$0")"
config=Release; [ "$1" = dev ] && config=Debug
version=${MARKETING_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}
build=${CURRENT_PROJECT_VERSION:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
id=$(security find-identity -p codesigning 2>/dev/null | awk '/"Crate Local Signing"/ {print $2; exit}')
xcodebuild -project Crate.xcodeproj -scheme Crate -configuration $config -destination 'platform=macOS,arch=arm64' -derivedDataPath build/xcode -quiet \
    ${version:+MARKETING_VERSION=$version} CURRENT_PROJECT_VERSION=$build CODE_SIGN_IDENTITY="${id:--}" build
# swapped in at the end, so a failed build leaves the last good app (and a running Crate keeps its bundle until the swap)
rm -rf build/Crate.app.new
cp -R build/xcode/Build/Products/$config/Crate.app build/Crate.app.new
rm -rf build/Crate.app && mv build/Crate.app.new build/Crate.app
echo "built build/Crate.app ${version:-(untagged)} ($build)"
