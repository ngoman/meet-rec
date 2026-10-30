#!/bin/bash
set -euo pipefail

SUPPORT="${MEETREC_SUPPORT_DIR:-$HOME/Library/Application Support/MeetRec}"
MODELS="$SUPPORT/models"
CLI="$HOME/.local/bin/meetrec"
MODEL=""
SHERPA_DIR="$SUPPORT/sherpa-onnx"
TMPS=()

restore_sherpa() {
    if [ ! -d "$SHERPA_DIR" ] && [ -d "$SHERPA_DIR.old" ]; then
        mv "$SHERPA_DIR.old" "$SHERPA_DIR"
    fi
}

cleanup() {
    local dir
    restore_sherpa
    for dir in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$dir" || true; done
}

trap cleanup EXIT
trap 'exit 143' TERM INT HUP
restore_sherpa

die() {
    echo "Ошибка: $*" >&2
    exit 1
}

TURBO_FILE="ggml-large-v3-turbo-q5_0.bin"
WHISPER_REV="5359861c739e955e79d9a303bcbc70fb988958b1"
VAD_REV="9ffd54a1e1ee413ddf265af9913beaf518d1639b"
TURBO_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/$WHISPER_REV/$TURBO_FILE"
TURBO_SHA="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
SMALL_FILE="ggml-small.bin"
SMALL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/$WHISPER_REV/$SMALL_FILE"
SMALL_SHA="1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
VAD_FILE="ggml-silero-v5.1.2.bin"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/$VAD_REV/$VAD_FILE"
VAD_SHA="29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
SHERPA_VERSION="2.0.1"
SHERPA_BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download"
SHERPA_ARM_SHA="4fcc6c77c8d8d2e2f04cfdc17c6fd224c01469b78529370eb9d8e0e5ec97ac79"
SHERPA_X64_SHA="029b5ea0a4bd2f0c034a337c0043019323fd06491728d7fc712592e3b558be52"
SEGMENTATION_FILE="sherpa-onnx-pyannote-segmentation-3-0.onnx"
SEGMENTATION_ARCHIVE_URL="$SHERPA_BASE/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
SEGMENTATION_ARCHIVE_SHA="24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488"
SEGMENTATION_SHA="220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079"
EMBEDDING_FILE="3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
EMBEDDING_URL="$SHERPA_BASE/speaker-recongition-models/$EMBEDDING_FILE"
EMBEDDING_SHA="aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2"

while [ $# -gt 0 ]; do
    case "$1" in
        --model) [ $# -ge 2 ] || die "нужно значение после --model"; MODEL="$2"; shift 2 ;;
        *) die "неизвестная опция: $1" ;;
    esac
done
case "$MODEL" in ""|turbo|small) ;; *) die "--model: turbo или small" ;; esac

find_brew() {
    command -v brew 2>/dev/null && return 0
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    done
    return 1
}

BREW="$(find_brew || true)"
if [ -z "$BREW" ]; then
    if [ ! -t 0 ]; then
        die "не найден Homebrew. Установите его командой из https://brew.sh и запустите ./install.sh снова"
    fi
    printf 'Homebrew не найден. Установить его сейчас? [y/N] '
    read -r answer
    case "$answer" in
        y|Y) /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ;;
        *) die "без Homebrew установка невозможна" ;;
    esac
    BREW="$(find_brew)" || die "Homebrew не установился"
fi
eval "$("$BREW" shellenv)"

for formula in ffmpeg whisper.cpp; do
    if "$BREW" list --formula "$formula" >/dev/null 2>&1; then
        echo "$formula: уже установлен"
    else
        echo "Устанавливаю $formula"
        "$BREW" install "$formula"
    fi
done

sha_of() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

fetch_model() {
    local file="$1" url="$2" sha="$3" dest="$MODELS/$1"
    if [ -f "$dest" ] && [ "$(sha_of "$dest")" = "$sha" ]; then
        echo "$file: уже скачан"
        return
    fi
    echo "Скачиваю $file"
    local part="$dest.part"
    if ! curl -L --fail -C - -o "$part" "$url" || [ "$(sha_of "$part")" != "$sha" ]; then
        rm -f "$part"
        curl -L --fail -o "$part" "$url" || die "не удалось скачать $file"
        [ "$(sha_of "$part")" = "$sha" ] || { rm -f "$part"; die "контрольная сумма $file не совпала"; }
    fi
    mv "$part" "$dest"
}

mkdir -p "$MODELS"
FETCH_MODEL="$MODEL"
if [ -z "$FETCH_MODEL" ] && [ -f "$SUPPORT/config.json" ] && [ -x "$CLI" ]; then
    case "$("$CLI" config 2>/dev/null | grep '"whisperCppModel"' || true)" in
        *"/$SMALL_FILE"*) FETCH_MODEL=small ;;
    esac
fi
if [ "$FETCH_MODEL" = "small" ]; then
    fetch_model "$SMALL_FILE" "$SMALL_URL" "$SMALL_SHA"
else
    fetch_model "$TURBO_FILE" "$TURBO_URL" "$TURBO_SHA"
fi
fetch_model "$VAD_FILE" "$VAD_URL" "$VAD_SHA"
fetch_model "$EMBEDDING_FILE" "$EMBEDDING_URL" "$EMBEDDING_SHA"

fetch_archive() {
    local url="$1" sha="$2" dest="$3"
    echo "Скачиваю $(basename "$url")"
    curl -L --fail -o "$dest" "$url" || die "не удалось скачать $(basename "$url")"
    [ "$(sha_of "$dest")" = "$sha" ] || die "контрольная сумма $(basename "$url") не совпала"
}

if [ -f "$MODELS/$SEGMENTATION_FILE" ] && [ "$(sha_of "$MODELS/$SEGMENTATION_FILE")" = "$SEGMENTATION_SHA" ]; then
    echo "$SEGMENTATION_FILE: уже скачан"
else
    tmp="$(mktemp -d)"
    TMPS+=("$tmp")
    fetch_archive "$SEGMENTATION_ARCHIVE_URL" "$SEGMENTATION_ARCHIVE_SHA" "$tmp/segmentation.tar.bz2"
    tar -xjf "$tmp/segmentation.tar.bz2" -C "$tmp" sherpa-onnx-pyannote-segmentation-3-0/model.onnx
    [ "$(sha_of "$tmp/sherpa-onnx-pyannote-segmentation-3-0/model.onnx")" = "$SEGMENTATION_SHA" ] || { rm -rf "$tmp"; die "контрольная сумма $SEGMENTATION_FILE не совпала"; }
    mv "$tmp/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" "$MODELS/$SEGMENTATION_FILE.part"
    mv "$MODELS/$SEGMENTATION_FILE.part" "$MODELS/$SEGMENTATION_FILE"
    rm -rf "$tmp"
fi

if [ "$(uname -m)" = "arm64" ]; then
    SHERPA_ARCH="arm64"; SHERPA_SHA="$SHERPA_ARM_SHA"
else
    SHERPA_ARCH="x64"; SHERPA_SHA="$SHERPA_X64_SHA"
fi
if [ -x "$SHERPA_DIR/bin/sherpa-onnx-offline-speaker-diarization" ] && [ "$(cat "$SHERPA_DIR/.sha256" 2>/dev/null)" = "$SHERPA_SHA" ]; then
    echo "sherpa-onnx $SHERPA_VERSION: уже установлен"
else
    tmp="$(mktemp -d)"
    TMPS+=("$tmp")
    fetch_archive "$SHERPA_BASE/v$SHERPA_VERSION/sherpa-onnx-v$SHERPA_VERSION-osx-$SHERPA_ARCH-shared-no-tts.tar.bz2" "$SHERPA_SHA" "$tmp/sherpa.tar.bz2"
    mkdir -p "$tmp/x"
    tar -xjf "$tmp/sherpa.tar.bz2" -C "$tmp/x" --strip-components=1 \
        "*/bin/sherpa-onnx-offline-speaker-diarization" "*/lib"
    echo "$SHERPA_SHA" > "$tmp/x/.sha256"
    rm -rf "$SHERPA_DIR.old"
    [ -d "$SHERPA_DIR" ] && mv "$SHERPA_DIR" "$SHERPA_DIR.old"
    mv "$tmp/x" "$SHERPA_DIR"
    rm -rf "$SHERPA_DIR.old" "$tmp"
fi
