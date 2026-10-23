#!/bin/bash
# Build the FTC Bridge menu bar app and put it in /Applications. Needs Xcode (or its command line tools).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FTC Bridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14" FTCBridge.swift -o "$APP/Contents/MacOS/FTCBridge"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"   # made by make-icon.swift
cp ../ftc-bridge "$APP/Contents/Resources/"  # the app runs it for backups and speed tests
codesign --force --sign - "$APP"  # ad-hoc signature, enough to run on this Mac

rm -rf "/Applications/FTC Bridge.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/FTC Bridge.app"
