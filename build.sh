#!/bin/sh
# Builds Auraverse.app. Does not launch it.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Auraverse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Auraverse "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/" # regenerate with: swift Icon/make_icon.swift
# Metal shaders -> default.metallib (what SwiftUI's ShaderLibrary.default loads).
# Needs the Metal toolchain: xcodebuild -downloadComponent MetalToolchain
xcrun metal -c Shaders/Shaders.metal -o .build/Shaders.air
xcrun metallib .build/Shaders.air -o "$APP/Contents/Resources/default.metallib"
codesign --force --sign - "$APP"
echo "Built $APP"
