#!/bin/zsh
# Сборка MacCool.app. Использование: ./build.sh [install]
set -e
cd "$(dirname "$0")"

APP=build/MacCool.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -O2 -mmacosx-version-min=14.0 -c Sources/smc.c -o build/smc.o
clang -O2 -mmacosx-version-min=14.0 Sources/maccoolctl.c build/smc.o -framework IOKit -o "$APP/Contents/Resources/maccoolctl"

swiftc -O -swift-version 5 -target arm64-apple-macos14 \
  -import-objc-header Sources/Bridging.h \
  Sources/*.swift build/smc.o \
  -framework IOKit -framework SwiftUI -framework ServiceManagement \
  -o "$APP/Contents/MacOS/MacCool"

cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacCool</string>
  <key>CFBundleDisplayName</key><string>MacCool</string>
  <key>CFBundleIdentifier</key><string>local.maccool</string>
  <key>CFBundleExecutable</key><string>MacCool</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Resources/maccoolctl"
codesign --force --sign - "$APP"
echo "Собрано: $APP"

if [[ "$1" == "install" ]]; then
  DEST=/Applications
  [[ -w $DEST ]] || DEST=~/Applications
  mkdir -p "$DEST"
  pkill -x MacCool 2>/dev/null || true
  sleep 1
  # Переносим, а не копируем: иначе Launchpad показывает две копии.
  rm -rf "$DEST/MacCool.app" && mv "$APP" "$DEST/"
  open "$DEST/MacCool.app"
  echo "Установлено в $DEST и запущено"
fi
