#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
FLAGS=()
[ -d "$PLUGINS" ] && FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
swift test --scratch-path "$HOME/Library/Caches/meetrec-build" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
