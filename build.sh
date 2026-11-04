#!/bin/sh
# Builds Crate.app with the Command Line Tools (no Xcode). Signs with the self-signed
# "Crate Local Signing" identity from the login keychain when it exists, so macOS keeps
# the app's privacy permissions (local network, network/removable volumes) across builds;
# ad hoc otherwise.
set -e
cd "$(dirname "$0")"
# built next to the app and swapped in at the end, so a failed build leaves the last good app (and a running Crate
# keeps its bundle until the swap)
app=build/Crate.app.new
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
# `./build.sh dev` skips optimisation: much quicker to build, slower at heavy work (cover dithering, scans)
opt=-O; [ "$1" = dev ] && opt=-Onone
swiftc $opt -j$(sysctl -n hw.ncpu) -parse-as-library -swift-version 5 -target arm64-apple-macos26 \
    $(find Sources -name "*.swift") \
    -o "$app/Contents/MacOS/Crate"
cp Resources/Info.plist "$app/Contents/"
mkdir -p "$app/Contents/Resources" && cp Resources/Icon/Crate.icns "$app/Contents/Resources/"   # drawn by Resources/Icon/make-icon.swift
cp Resources/Fonts/ChicagoFLF.ttf "$app/Contents/Resources/"   # public-domain Chicago revival for the iPod LCD
id=$(security find-identity -p codesigning | awk '/"Crate Local Signing"/ {print $2; exit}')
codesign --force --sign "${id:--}" --identifier nl.jrvgr.crate "$app"
rm -rf build/Crate.app && mv "$app" build/Crate.app
echo built build/Crate.app
