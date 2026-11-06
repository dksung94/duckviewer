#!/usr/bin/env bash
# DuckViewer.app 번들을 build/ 아래에 만든다.
# 사용법: scripts/bundle.sh [debug|release]   (기본값 release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DuckViewer.app"
VERSION="0.1.0"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DuckViewer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DuckViewer"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DuckViewer</string>
    <key>CFBundleDisplayName</key><string>DuckViewer</string>
    <key>CFBundleIdentifier</key><string>com.dksung94.duckviewer</string>
    <key>CFBundleExecutable</key><string>DuckViewer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PDF Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# 샌드박스 없이 ad-hoc 서명 (임의 CLI 실행과 터미널 PTY가 필요하다)
codesign --force --sign - "$APP"
echo "Built $APP"
