#!/bin/bash

APP_NAME="Absentweaks"
SOURCE_DIR="Source"
BUILD_DIR="Build"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "🧹 Cleaning..."
rm -rf "$APP_BUNDLE"
rm -f "$APP_NAME"

echo "🏗  Compiling..."
swiftc ${SOURCE_DIR}/main.swift \
       ${SOURCE_DIR}/AppDelegate.swift \
       ${SOURCE_DIR}/MouseTracker.swift \
       ${SOURCE_DIR}/WindowDetector.swift \
       ${SOURCE_DIR}/DisplayMover.swift \
       ${SOURCE_DIR}/SwipeTracker.swift \
       ${SOURCE_DIR}/OverlayIndicator.swift \
       ${SOURCE_DIR}/StateController.swift \
       ${SOURCE_DIR}/Logger.swift \
       -o "$APP_NAME"

if [ $? -ne 0 ]; then
    echo "❌ Compilation failed"
    exit 1
fi

echo "📦 Bundling into ${APP_BUNDLE}..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Generate icons if script and source exist
if [ -f "generate_icons.sh" ] && [ -f "Assets/icon.png" ]; then
    echo "🎨 Generating icons..."
    ./generate_icons.sh
fi

# Move binary
mv "$APP_NAME" "$MACOS_DIR/"

# Copy Icon if exists
if [ -f "Assets/AppIcon.icns" ]; then
    cp "Assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Copy MenuBarIcon if exists (for status bar)
if [ -f "Assets/MenuBarIcon.png" ]; then
    cp "Assets/MenuBarIcon.png" "${RESOURCES_DIR}/MenuBarIcon.png"
fi

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.user.absentweaks</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Create PkgInfo
echo "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# Touch the app to force Finder update
touch "$APP_BUNDLE"

echo "✅ Done! Application is ready at ./${APP_BUNDLE}"
echo "   To run: open ${APP_BUNDLE}"
