#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$HOME/Library/Caches/meetrec-build"
APP="$HOME/Applications/MeetRec.app"

cd "$ROOT"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

STAMP_FILE="$SCRATCH/installed.sha"
STAMP="$(cat "$BIN/MeetRecApp" "$BIN/meetrec" "$ROOT/scripts/build.sh" | shasum -a 256 | cut -d' ' -f1)"
if [ -x "$APP/Contents/MacOS/MeetRecApp" ] && [ -x "$APP/Contents/MacOS/meetrec" ] && [ -f "$STAMP_FILE" ] \
    && [ "$(cat "$STAMP_FILE")" = "$STAMP" ] && codesign --verify --strict "$APP" 2>/dev/null; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$APP/Contents/MacOS/meetrec" "$HOME/.local/bin/meetrec"
    echo "Без изменений: $APP"
    exit 0
fi

rm -f "$STAMP_FILE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/MeetRecApp" "$APP/Contents/MacOS/MeetRecApp"
cp "$BIN/meetrec" "$APP/Contents/MacOS/meetrec"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.meetrec.app</string>
    <key>CFBundleName</key><string>MeetRec</string>
    <key>CFBundleDisplayName</key><string>MeetRec</string>
    <key>CFBundleExecutable</key><string>MeetRecApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.5</string>
    <key>NSMicrophoneUsageDescription</key><string>MeetRec записывает ваш голос с микрофона во время встреч.</string>
    <key>NSAudioCaptureUsageDescription</key><string>MeetRec записывает системный звук, чтобы сохранить голоса собеседников.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier local.meetrec.app "$APP/Contents/MacOS/meetrec"
codesign --force --sign - --identifier local.meetrec.app "$APP"

mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/meetrec" "$HOME/.local/bin/meetrec"
echo "$STAMP" > "$STAMP_FILE"

echo "Готово: $APP"
