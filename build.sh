#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="${PROJECT_DIR}/GeminiFlow.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
APPLICATIONS_DIR="${HOME}/Applications"

echo "Building GeminiFlow..."

mkdir -p "${MACOS}"
mkdir -p "${RESOURCES}"
mkdir -p "${APPLICATIONS_DIR}"

cat << 'PLIST' > "${CONTENTS}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GeminiFlow</string>
    <key>CFBundleIdentifier</key>
    <string>com.google.internal.geminiflow</string>
    <key>CFBundleName</key>
    <string>GeminiFlow</string>
    <key>CFBundleDisplayName</key>
    <string>GeminiFlow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>GeminiFlow uses your microphone when you hold the Fn key to transcribe your voice.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>GeminiFlow uses on-device speech recognition for offline transcription.</string>
</dict>
</plist>
PLIST

echo "Compiling main.m with clang..."
/usr/bin/clang -fobjc-arc -O2 \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Speech \
    -framework ApplicationServices \
    -framework Security \
    "${PROJECT_DIR}/main.m" \
    -o "${MACOS}/GeminiFlow"

echo "Signing application bundle..."
# Sign with the stable self-signed identity so macOS privacy permissions (Mic, Speech, Accessibility)
# survive rebuilds. Ad-hoc signatures change on every build, which silently invalidates those grants.
SIGN_IDENTITY_NAME="GeminiFlow Local Signing"
SIGN_HASH=$(/usr/bin/security find-certificate -c "${SIGN_IDENTITY_NAME}" -Z 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}')
if [ -n "${SIGN_HASH}" ]; then
    /usr/bin/codesign --force --deep --sign "${SIGN_HASH}" "${APP_BUNDLE}"
    echo "Signed with stable identity '${SIGN_IDENTITY_NAME}' (${SIGN_HASH})."
else
    echo "WARNING: '${SIGN_IDENTITY_NAME}' not found in keychain; falling back to ad-hoc signing (permissions will reset)."
    /usr/bin/codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo "Syncing to ${APPLICATIONS_DIR}/GeminiFlow.app..."
rm -rf "${APPLICATIONS_DIR}/GeminiFlow.app"
cp -R "${APP_BUNDLE}" "${APPLICATIONS_DIR}/GeminiFlow.app"

echo "GeminiFlow build complete!"
