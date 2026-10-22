#!/bin/bash
set -euo pipefail

#  build.sh
#  Compiles HiDPIDisplayManager into a production macOS .app bundle.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$PROJECT_DIR/Sources"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/HiDPIDisplayManager.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Building HiDPIDisplayManager..."

# 1. Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 2. Select compatible SDK (avoiding mismatched unreleased SDKs)
SDK_PATH=""
for candidate in \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
do
    if [ -d "$candidate" ]; then
        SDK_PATH="$candidate"
        break
    fi
done

if [ -z "$SDK_PATH" ]; then
    SDK_PATH="$(xcrun --show-sdk-path)"
fi

echo "==> Using SDK: $SDK_PATH"

# 3. Compile Swift sources with Bridging Header
echo "==> Compiling Swift sources..."
swiftc \
    -O \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macos13.0 \
    -import-objc-header "$SOURCES_DIR/PrivateDisplayAPIs.h" \
    -framework CoreGraphics \
    -framework AppKit \
    -framework Foundation \
    -framework IOKit \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework ServiceManagement \
    -F /System/Library/PrivateFrameworks \
    -framework SkyLight \
    "$SOURCES_DIR/DisplayModels.swift" \
    "$SOURCES_DIR/DisplayManager.swift" \
    "$SOURCES_DIR/Arm64DDC.swift" \
    "$SOURCES_DIR/OSDManager.swift" \
    "$SOURCES_DIR/AudioManager.swift" \
    "$SOURCES_DIR/LaunchAtLoginManager.swift" \
    "$SOURCES_DIR/MenuBarView.swift" \
    "$SOURCES_DIR/App.swift" \
    -o "$MACOS_DIR/HiDPIDisplayManager"

# 4. Copy Plist & Resources
echo "==> Packaging .app bundle..."
cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

# 5. Ad-hoc Code Sign with Entitlements (No Sandbox)
echo "==> Applying ad-hoc code signature..."
codesign --force --deep --sign - \
    --entitlements "$PROJECT_DIR/HiDPIDisplayManager.entitlements" \
    "$APP_BUNDLE"

# 6. Install to /Applications for persistent macOS login item & launchd support
echo "==> Installing to /Applications/HiDPIDisplayManager.app..."
rm -rf "/Applications/HiDPIDisplayManager.app"
cp -R "$APP_BUNDLE" "/Applications/HiDPIDisplayManager.app"
codesign --force --deep --sign - \
    --entitlements "$PROJECT_DIR/HiDPIDisplayManager.entitlements" \
    "/Applications/HiDPIDisplayManager.app"

echo "==> Successfully built and installed: /Applications/HiDPIDisplayManager.app"
echo "==> To run: open /Applications/HiDPIDisplayManager.app"
