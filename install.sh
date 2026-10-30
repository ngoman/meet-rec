#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="${MEETREC_SUPPORT_DIR:-$HOME/Library/Application Support/MeetRec}"
MODELS="$SUPPORT/models"
APP="$HOME/Applications/MeetRec.app"
CLI="$HOME/.local/bin/meetrec"
DEFAULT_OUTPUT='~/Documents/MeetRec'

TURBO_FILE="ggml-large-v3-turbo-q5_0.bin"
SMALL_FILE="ggml-small.bin"

OUTPUT_DIR=""
ENGINE=""
MODEL=""
SUMMARY=""
NO_RESTART=0
FORCE=0

usage() {
    cat <<USAGE
Установка и обновление MeetRec.

Использование: ./install.sh [опции]

  --output-dir PATH           папка для записей встреч (по умолчанию спросит, предложит $DEFAULT_OUTPUT)
  --engine whisper.cpp|openai-whisper
                              движок распознавания (по умолчанию whisper.cpp)
  --model turbo|small         модель whisper.cpp: turbo (large-v3-turbo-q5_0, по умолчанию) или small
  --summary claude|codex|off  саммари: через Claude Code, через Codex (подписка ChatGPT) или выключить.
                              Без флага для нового конфига выбирается автоматически
  --no-restart                не перезапускать и не открывать приложение
  --force                     собрать, даже если сейчас идет запись или обработка (без перезапуска)
  -h, --help                  эта справка

Скрипт можно запускать повторно: он же обновляет установку. Существующий конфиг меняется
только теми опциями, которые заданы явно.
USAGE
}

die() {
    echo "Ошибка: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir) [ $# -ge 2 ] || die "нужен путь после --output-dir"; OUTPUT_DIR="$2"; shift 2 ;;
        --engine) [ $# -ge 2 ] || die "нужно значение после --engine"; ENGINE="$2"; shift 2 ;;
        --model) [ $# -ge 2 ] || die "нужно значение после --model"; MODEL="$2"; shift 2 ;;
        --summary) [ $# -ge 2 ] || die "нужно значение после --summary"; SUMMARY="$2"; shift 2 ;;
        --no-restart) NO_RESTART=1; shift ;;
        --force) FORCE=1; NO_RESTART=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "неизвестная опция: $1" ;;
    esac
done

case "$ENGINE" in ""|whisper.cpp|openai-whisper) ;; *) die "--engine: whisper.cpp или openai-whisper" ;; esac
case "$MODEL" in ""|turbo|small) ;; *) die "--model: turbo или small" ;; esac
case "$SUMMARY" in ""|claude|codex|off) ;; *) die "--summary: claude, codex или off" ;; esac

valid_dir() {
    case "$1" in /*|"~"|"~/"*) return 0 ;; *) return 1 ;; esac
}
if [ -n "$OUTPUT_DIR" ] && ! valid_dir "$OUTPUT_DIR"; then
    die "--output-dir: нужен абсолютный путь или путь с ~, получено: $OUTPUT_DIR"
fi

[ "$(uname -s)" = "Darwin" ] || die "MeetRec работает только на macOS"
version="$(sw_vers -productVersion)"
if [ "$(printf '%s\n14.5\n' "$version" | sort -V | head -n1)" != "14.5" ]; then
    die "нужна macOS 14.5 или новее, сейчас $version"
fi
if [ "$(uname -m)" != "arm64" ]; then
    echo "Предупреждение: Intel Mac, распознавание будет медленным. Рекомендуется Apple Silicon."
fi

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Не установлены Command Line Tools. Запускаю установку."
    xcode-select --install || true
    echo "Дождитесь окончания установки и запустите ./install.sh снова."
    exit 1
fi

swift_bin="$(xcrun --find swift 2>/dev/null || true)"
swift_version=""
[ -n "$swift_bin" ] && swift_version="$("$swift_bin" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -n1 || true)"
if [ -n "$swift_bin" ] && [ -z "$swift_version" ]; then
    echo "swift не запускается. Если выбран Xcode, примите лицензию: sudo xcodebuild -license accept" >&2
    exit 1
fi
if [ -z "$swift_version" ] || [ "$(printf '%s\n6.0\n' "$swift_version" | sort -V | head -n1)" != "6.0" ]; then
    echo "Для сборки нужен Swift 6.0 или новее (Command Line Tools 16+ или Xcode 16+), найдено: ${swift_version:-ничего}." >&2
    echo "Посмотрите доступные обновления: softwareupdate --list" >&2
    echo "Затем поставьте Command Line Tools: softwareupdate -i \"Command Line Tools for Xcode-NN\" (NN из списка)," >&2
    echo "либо установите свежий Xcode, и запустите ./install.sh снова." >&2
    exit 1
fi

app_state() {
    [ -x "$CLI" ] || return 0
    "$CLI" status --json 2>/dev/null | grep -Eo '"state" *: *"[a-z]+"' | head -n1 | sed 's/.*: *"\(.*\)"/\1/' || true
}
case "$(app_state)" in
    recording|processing)
        if [ "$FORCE" = 0 ]; then
            die "Идет запись или обработка, повторите после (или запустите с --force)"
        fi
        ;;
esac

"$ROOT/scripts/deps.sh" ${MODEL:+--model "$MODEL"}

BREW="$(command -v brew 2>/dev/null || true)"
if [ -z "$BREW" ]; then
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$candidate" ] && { BREW="$candidate"; break; }
    done
fi
eval "$("$BREW" shellenv)"

"$ROOT/scripts/build.sh"

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
        echo
        echo "Каталог ~/.local/bin не в PATH. Добавьте строку в ~/.zprofile и откройте новый терминал:"
        echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zprofile"
        ;;
esac

config_existed=0
[ -f "$SUPPORT/config.json" ] && config_existed=1
"$CLI" config >/dev/null

if [ -z "$OUTPUT_DIR" ] && [ "$config_existed" = 0 ]; then
    OUTPUT_DIR="$DEFAULT_OUTPUT"
    if [ -t 0 ]; then
        while true; do
            printf 'Папка для записей встреч [%s]: ' "$DEFAULT_OUTPUT"
            read -r answer
            [ -z "$answer" ] && answer="$DEFAULT_OUTPUT"
            if valid_dir "$answer"; then
                OUTPUT_DIR="$answer"
                break
            fi
            echo "Нужен абсолютный путь или путь с ~, попробуйте еще раз."
        done
    fi
fi
if [ -n "$OUTPUT_DIR" ]; then
    "$CLI" config set outputDir "$OUTPUT_DIR"
    mkdir -p "${OUTPUT_DIR/#\~/$HOME}"
fi
[ -n "$ENGINE" ] && "$CLI" config set engine "$ENGINE"
[ "$MODEL" = "small" ] && "$CLI" config set whisperCppModel "$MODELS/$SMALL_FILE"
[ "$MODEL" = "turbo" ] && "$CLI" config set whisperCppModel "$MODELS/$TURBO_FILE"

claude_found=0
for candidate in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -x "$candidate" ] && claude_found=1
done
if [ "$claude_found" = 0 ] && path_claude="$(command -v claude 2>/dev/null)"; then
    claude_found=1
    "$CLI" config set claudeBin "$path_claude"
fi
codex_found=0
for candidate in "$HOME/.local/bin/codex" "$HOME/.npm-global/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
    [ -x "$candidate" ] && codex_found=1
done
if [ "$codex_found" = 0 ] && path_codex="$(command -v codex 2>/dev/null)"; then
    codex_found=1
    "$CLI" config set codexBin "$path_codex"
fi

if [ -z "$SUMMARY" ] && [ "$config_existed" = 0 ]; then
    if [ "$claude_found" = 1 ]; then SUMMARY=claude
    elif [ "$codex_found" = 1 ]; then SUMMARY=codex
    else SUMMARY=off
    fi
fi
case "$SUMMARY" in
    claude|codex)
        "$CLI" config set summaryProvider "$SUMMARY"
        "$CLI" config set summary true
        if [ "$SUMMARY" = claude ] && [ "$claude_found" = 0 ]; then
            echo
            echo "Claude Code CLI не найден, саммари работать не будет, пока его не установить."
        elif [ "$SUMMARY" = codex ] && [ "$codex_found" = 0 ]; then
            echo
            echo "Codex CLI не найден. Установите его (brew install --cask codex) и войдите: codex login"
        fi
        ;;
    off)
        "$CLI" config set summary false
        echo
        echo "Саммари выключено. Включить: meetrec config set summary true"
        ;;
esac

if [ "$NO_RESTART" = 0 ]; then
    case "$(app_state)" in
        recording|processing) echo; echo "Идет запись или обработка, приложение не перезапущено. Перезапустите его позже." ;;
        "") open "$APP" ;;
        *)
            pkill -x MeetRecApp || true
            for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MeetRecApp >/dev/null || break; sleep 0.5; done
            if pgrep -x MeetRecApp >/dev/null; then
                echo "Старая версия приложения не завершилась, перезапустите MeetRec вручную"
            else
                open "$APP"
            fi
            ;;
    esac
fi

if [ "$FORCE" = 1 ]; then
    echo
    echo "Использован --force: перезапустите приложение MeetRec вручную, чтобы подхватить новую версию."
fi

cat <<NEXT

Готово. Дальнейшие шаги:
  1. При первой записи разрешите MeetRec доступ к микрофону и уведомлениям, а в
     Системные настройки > Конфиденциальность и безопасность > Запись экрана и системного звука
     включите MeetRec в разделе «Только системный звук».
  2. Запись переключается хоткеем Ctrl+Option+Cmd+R или командами meetrec start и meetrec stop.
  3. Иконка MeetRec в строке меню справа. Если ее не видно, строка меню переполнена или скрыта вырезом экрана:
     уберите лишние значки перетаскиванием с зажатым Cmd.
NEXT
