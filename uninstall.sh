#!/bin/bash
set -euo pipefail

SUPPORT="${MEETREC_SUPPORT_DIR:-$HOME/Library/Application Support/MeetRec}"
APP="$HOME/Applications/MeetRec.app"
CLI="$HOME/.local/bin/meetrec"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Удаляет приложение MeetRec и команду meetrec. Кэш сборки, модели и конфиг удаляются только после подтверждения."
    echo "Записи встреч скрипт не трогает никогда."
    exit 0
fi

ask() {
    [ -t 0 ] || return 1
    printf '%s [y/N] ' "$1"
    read -r answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

state=""
[ -x "$CLI" ] && state="$("$CLI" status --json 2>/dev/null | grep -Eo '"state" *: *"[a-z]+"' | head -n1 | sed 's/.*: *"\(.*\)"/\1/' || true)"
case "$state" in
    recording|processing)
        echo "Сейчас идет запись или обработка, удаление прервет ее."
        ask "Продолжить?" || { echo "Отменено."; exit 1; }
        ;;
esac

pkill -x MeetRecApp 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MeetRecApp >/dev/null || break; sleep 0.5; done

if [ -L "$CLI" ] && [ "$(readlink "$CLI")" = "$APP/Contents/MacOS/meetrec" ]; then
    rm "$CLI"
    echo "Удалена команда $CLI"
fi
if [ -d "$APP" ]; then
    rm -r "$APP"
    echo "Удалено приложение $APP"
fi

CACHE="$HOME/Library/Caches/meetrec-build"
if [ -d "$CACHE" ] && ask "Удалить кэш сборки ($CACHE)?"; then
    rm -r "$CACHE"
fi
if [ -d "$SUPPORT/models" ] && ask "Удалить скачанные модели ($SUPPORT/models)?"; then
    rm -r "$SUPPORT/models"
fi
if [ -f "$SUPPORT/config.json" ] && ask "Удалить конфиг ($SUPPORT/config.json)?"; then
    rm "$SUPPORT/config.json"
fi

rm -rf "$SUPPORT/updates" "$SUPPORT/update-rollback"
rm -f "$SUPPORT/update-state.json" "$SUPPORT/update.log"

echo "Готово. Папка записей встреч и необработанные сессии ($SUPPORT/sessions) не тронуты."
