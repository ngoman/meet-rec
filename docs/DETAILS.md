# MeetRec: подробности

Справочник для тех, кому мало [README](../README.md).

## Требования

- macOS 14.5 или новее с Command Line Tools 16+ (Swift 6.0+). Проверено на macOS 26 и Swift 6.4.
- Apple Silicon рекомендуется, на Intel распознавание будет медленным.
- Около 1.5 GB на диске (модели, ffmpeg, whisper.cpp) и интернет при установке.
- Если Swift старше 6.0, установщик остановится до загрузок и подскажет, как обновить Command Line Tools (`softwareupdate --list`).
- Homebrew установщик предложит поставить сам.

## Установщик

`./install.sh` ставит ffmpeg и whisper.cpp через Homebrew, скачивает модели с проверкой sha256, собирает приложение в `~/Applications/MeetRec.app`, делает команду `~/.local/bin/meetrec` и запускает приложение. Повторный запуск безопасен: ничего не перекачивает и не пересобирает без изменений. Если идет запись или обработка, установщик откажется работать.

Флаги:

- `--output-dir PATH` папка для записей. Без флага при первой установке спросит (по умолчанию `~/Documents/MeetRec`).
- `--model turbo|small` модель whisper.cpp: `turbo` (large-v3-turbo-q5_0, по умолчанию, точнее) или `small` (быстрее и легче).
- `--engine whisper.cpp|openai-whisper` движок распознавания.
- `--no-restart` не перезапускать приложение.
- `--force` собрать, даже если идет запись или обработка (приложение не перезапускается).
- `--help` справка.

Если `~/.local/bin` не в PATH, установщик подскажет строку для `~/.zprofile`.

`./uninstall.sh` удаляет приложение и команду `meetrec`. Кэш сборки, модели и конфиг удаляются только после подтверждения. Записи встреч не трогаются никогда.

## Разрешения

Уведомления macOS спросит при первом запуске приложения, микрофон и системный звук при первой записи. Приложение подписано ad-hoc, поэтому после пересборки macOS может спросить разрешения заново.

## Командная строка

```
meetrec start [--title T] [--no-summary]   начать запись через приложение (запустит его, если нужно)
meetrec stop [--wait]                      остановить; с --wait дождаться обработки и напечатать путь
meetrec status [--json]
meetrec record [--title T] [--no-summary]  запись прямо из терминала до Ctrl+C
meetrec process <id|path> | --pending      обработать сессию или все необработанные
meetrec list
meetrec config                             показать настройки
meetrec config set <ключ> <значение>
```

Коды выхода: 0 успех, 1 ошибка, 2 приложение недоступно. Предупреждения обработки выводятся в stderr.

`meetrec record` пишет системный звук, только если у терминала есть к нему доступ (у iTerm2 его нет), поэтому лучше `start` и `stop`.

## Файлы

Результат: `<папка встреч>/<id>/` с `audio.m4a`, `transcript.md`, `transcript.json`, `summary.md`, `session.json`.

Сырые дорожки лежат в `~/Library/Application Support/MeetRec/sessions/<id>/` до успешной обработки. При ошибке они не теряются: сессию можно обработать повторно из панели («Незавершенные») или командой `meetrec process`.

## Папка встреч и iCloud

Сменить папку: в панели «Изменить…», командой `meetrec config set outputDir <путь>` или флагом `--output-dir` при установке. Путь должен быть абсолютным или начинаться с `~`. Приложение подхватывает новое значение без перезапуска, отсутствующая папка создается.

Корень iCloud Drive на диске: `~/Library/Mobile Documents/com~apple~CloudDocs/` (в Finder «iCloud Drive»). Если включено «Рабочий стол и Документы в iCloud», синхронизируется и `~/Documents`. Аудио занимает порядка 40 MB на час записи.

## Саммари

Нужен Claude Code CLI (`claude`) с залогиненной подпиской. Текст транскрипта отправляется в Anthropic. Если `claude` не найден, саммари пропускается с предупреждением. Выключить: галочка в панели, `meetrec config set summary false` или `meetrec start --no-summary` для одной записи.

## Движки и модели

- `whisper.cpp` (по умолчанию): быстрый, работает через Metal. Модели в `~/Library/Application Support/MeetRec/models/`. Перейти на легкую модель: `./install.sh --model small`.
- `openai-whisper`: Python-пакет, ставится отдельно (`pip3 install openai-whisper`), модель задается ключом `whisperModel`. Включить: `meetrec config set engine openai-whisper`.

## Настройки

Файл `~/Library/Application Support/MeetRec/config.json`. Недостающие ключи берутся по умолчанию, менять удобно через `meetrec config set`.

| Ключ | По умолчанию | Описание |
| --- | --- | --- |
| `outputDir` | `~/Documents/MeetRec` | папка встреч |
| `language` | `ru` | язык речи, `auto` для автоопределения |
| `engine` | `whisper.cpp` | `whisper.cpp` или `openai-whisper` |
| `whisperCppBin` | `/opt/homebrew/bin/whisper-cli` | бинарь whisper.cpp |
| `whisperCppModel` | `.../models/ggml-large-v3-turbo-q5_0.bin` | модель whisper.cpp |
| `vadModel` | `.../models/ggml-silero-v5.1.2.bin` | VAD-модель; без нее распознавание идет без VAD |
| `whisperBin` | `/opt/homebrew/bin/whisper` | бинарь openai-whisper |
| `whisperModel` | `small` | модель openai-whisper |
| `ffmpegBin` | `/opt/homebrew/bin/ffmpeg` | ffmpeg |
| `claudeBin` | `~/.local/bin/claude` | Claude Code CLI |
| `summary` | `true` | делать саммари |
| `summaryModel` | `sonnet` | модель для саммари |
| `myName` | `Я` | подпись вашей дорожки |
| `othersName` | `Собеседники` | подпись дорожки собеседников |
| `hotkey` | `ctrl+opt+cmd+r` | модификаторы `ctrl`, `opt`, `cmd`, `shift` и буква или цифра через `+`; применяется после перезапуска приложения |

Если указанного бинаря нет, он ищется в `/opt/homebrew/bin` и `/usr/local/bin`; для `claude` еще в `~/.local/bin` и `~/.claude/local`, для openai-whisper в `~/Library/Python/*/bin`. Найденный путь в конфиг не записывается.

## Ограничения

- Длинные встречи обрабатываются заметное время: распознавание, затем сжатие и саммари.
- Когда на одной дорожке говорят одновременно, тихий голос может потеряться.
- Без наушников микрофон слышит собеседников из динамиков. Эхо частично вычищается, но наушники надежнее.
- Подпись ad-hoc: после пересборки разрешения могут спросить снова.

## Разработка

```
scripts/build.sh   сборка и установка в ~/Applications и ~/.local/bin
scripts/test.sh    тесты (swift-testing, нужны только Command Line Tools)
swift scripts/make-icon.swift   перегенерировать Resources/AppIcon.icns
```

Если в уведомлениях или Finder осталась старая иконка, кэш LaunchServices и уведомлений обновится после повторного входа в систему или перезагрузки.

Исходники: `Sources/MeetRecCore` (запись, обработка, конфиг), `Sources/MeetRecApp` (приложение: AppKit, панель на SwiftUI), `Sources/meetrec` (CLI), `Sources/CSupport` (Objective-C и C). Переменная `MEETREC_SUPPORT_DIR` подменяет каталог данных, только для тестов.
