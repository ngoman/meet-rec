#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "Использование: scripts/package.sh <версия без v>" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Версия должна быть вида 1.2.3, получено: $VERSION" >&2; exit 1; }
ARCH="$(uname -m)"
DIST="$ROOT/dist"

rm -rf "$DIST"
mkdir -p "$DIST"
MEETREC_VERSION="$VERSION" MEETREC_APP_DEST="$DIST/MeetRec.app" "$ROOT/scripts/build.sh"

cd "$DIST"
ditto -c -k --sequesterRsrc --keepParent MeetRec.app "MeetRec-$ARCH.zip"
shasum -a 256 "MeetRec-$ARCH.zip" > "MeetRec-$ARCH.zip.sha256"
echo "Готово: $DIST/MeetRec-$ARCH.zip"
