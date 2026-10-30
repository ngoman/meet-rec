#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$HOME/Library/Caches/meetrec-build"
APP="${MEETREC_APP_DEST:-$HOME/Applications/MeetRec.app}"
INSTALL=1
[ -n "${MEETREC_APP_DEST:-}" ] && INSTALL=0
DR='designated => identifier "local.meetrec.app"'

cd "$ROOT"
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
if [ -n "${MEETREC_VERSION:-}" ]; then
    VERSION="${MEETREC_VERSION#v}"
    [[ "$VERSION" =~ $VERSION_RE ]] || { echo "MEETREC_VERSION должна быть вида 1.2.3, получено: $MEETREC_VERSION" >&2; exit 1; }
else
    VERSION="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"
    VERSION="${VERSION#v}"
    [[ "$VERSION" =~ $VERSION_RE ]] || VERSION="0.0.0"
fi
[ -f "$ROOT/Resources/AppIcon.icns" ] || { echo "Нет Resources/AppIcon.icns, сгенерируйте: swift scripts/make-icon.swift" >&2; exit 1; }
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

STAMP_FILE="$SCRATCH/installed.sha"
STAMP="$( (cat "$BIN/MeetRecApp" "$BIN/meetrec" "$ROOT/scripts/build.sh" "$ROOT/scripts/deps.sh" "$ROOT/Resources/AppIcon.icns"; echo "$VERSION") | shasum -a 256 | cut -d' ' -f1)"
if [ "$INSTALL" = 1 ] && [ -x "$APP/Contents/MacOS/MeetRecApp" ] && [ -x "$APP/Contents/MacOS/meetrec" ] && [ -f "$STAMP_FILE" ] \
    && [ "$(cat "$STAMP_FILE")" = "$STAMP" ] && codesign --verify --strict "$APP" 2>/dev/null; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$APP/Contents/MacOS/meetrec" "$HOME/.local/bin/meetrec"
    echo "Без изменений: $APP"
    exit 0
fi

[ "$INSTALL" = 1 ] && rm -f "$STAMP_FILE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/MeetRecApp" "$APP/Contents/MacOS/MeetRecApp"
cp "$BIN/meetrec" "$APP/Contents/MacOS/meetrec"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/scripts/deps.sh" "$APP/Contents/Resources/deps.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.meetrec.app</string>
    <key>CFBundleName</key><string>MeetRec</string>
    <key>CFBundleDisplayName</key><string>MeetRec</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>MeetRecApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.5</string>
    <key>NSMicrophoneUsageDescription</key><string>MeetRec записывает ваш голос с микрофона во время встреч.</string>
    <key>NSAudioCaptureUsageDescription</key><string>MeetRec записывает системный звук, чтобы сохранить голоса собеседников.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier local.meetrec.app -r="$DR" "$APP/Contents/MacOS/meetrec"
codesign --force --sign - --identifier local.meetrec.app -r="$DR" "$APP/Contents/MacOS/MeetRecApp"
codesign --force --sign - --identifier local.meetrec.app -r="$DR" "$APP"

if [ "$INSTALL" = 0 ]; then
    echo "Готово: $APP"
    exit 0
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true

mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/meetrec" "$HOME/.local/bin/meetrec"
echo "$STAMP" > "$STAMP_FILE"

echo "Готово: $APP"
