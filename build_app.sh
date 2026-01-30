#!/bin/bash

APP_NAME="CursorOverlay"
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
       ${SOURCE_DIR}/OverlayIndicator.swift \
       ${SOURCE_DIR}/Logger.swift \
       ${SOURCE_DIR}/StateController.swift \
       -o "$APP_NAME"

if [ $? -ne 0 ]; then
    echo "❌ Compilation failed"
    exit 1
fi

echo "📦 Bundling into ${APP_BUNDLE}..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

if [ -f "Assets/AppIcon.icns" ]; then
    cp "Assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Move binary
mv "$APP_NAME" "$MACOS_DIR/"

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.user.cursoroverlay</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/> <!-- This hides the app from Dock (Menu bar app) -->
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Create PkgInfo
echo "APPL????" > "${CONTENTS_DIR}/PkgInfo"

echo "✅ Done! Application is ready at ./${APP_BUNDLE}"
echo "   To run: open ${APP_BUNDLE}"
