#!/bin/sh
# Builds Crate.app with the Command Line Tools (no Xcode). Signs with the self-signed
# "Crate Local Signing" identity from the login keychain when it exists, so macOS keeps
# the app's privacy permissions (local network, network/removable volumes) across builds;
# ad hoc otherwise.
set -e
cd "$(dirname "$0")"
rm -rf build/Crate.app
mkdir -p build/Crate.app/Contents/MacOS
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos26 \
    *.swift \
    -o build/Crate.app/Contents/MacOS/Crate
cp Info.plist build/Crate.app/Contents/
id=$(security find-identity -p codesigning | awk '/"Crate Local Signing"/ {print $2; exit}')
codesign --force --sign "${id:--}" --identifier nl.jaccogroen.crate build/Crate.app
echo built build/Crate.app
