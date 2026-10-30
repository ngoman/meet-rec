import AppKit
import MeetRecCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Название (необязательно)", text: $model.title)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isRecording || model.isBusy)

            Picker("Собеседников:", selection: Binding(get: { model.speakers }, set: { model.setSpeakers($0) })) {
                ForEach(["1", "2", "3", "4", "5", "6"], id: \.self) { Text($0).tag($0) }
                Text("Авто").tag("auto")
            }
            .pickerStyle(.menu)

            HStack {
                Button(model.isRecording ? "Остановить" : "Начать запись") { model.toggleRecording() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
                Spacer()
                if model.isRecording {
                    Text(Transcript.formatTime(model.elapsed)).monospacedDigit()
                }
            }

            if let hotkey = model.hotkeyLabel {
                Text("Хоткей: \(hotkey)").font(.caption).foregroundStyle(.secondary)
            }

            if model.isRecording {
                LevelRow(name: "Система", db: model.systemDB, silent: model.systemSilent)
                LevelRow(name: "Микрофон", db: model.micDB, silent: model.micSilent)
            }

            if let message = model.message {
                WarningText(text: message)
                if model.permissionIssue {
                    Button("Открыть настройки") { model.openPrivacySettings() }
                }
            }

            if model.processingID != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.processingStep).font(.caption)
                    if let fraction = model.processingFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    if model.queued.count > 1 {
                        Text("В очереди: \(model.queued.count - 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if !model.pending.isEmpty {
                Divider()
                Text("Незавершенные").font(.headline)
                ForEach(model.pending.prefix(8), id: \.id) { info in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(info.id).font(.caption).lineLimit(1)
                            if let error = info.error {
                                WarningText(text: error, tint: .red).lineLimit(2)
                            }
                        }
                        Spacer()
                        if info.state == .failed {
                            Button("Удалить") { model.delete(info.id) }
                        }
                        Button("Обработать") { model.enqueue(info.id) }
                    }
                }
                if model.pending.count > 8 {
                    Text("и еще \(model.pending.count - 8)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if !model.recent.isEmpty {
                Divider()
                Text("Последние встречи").font(.headline)
                ForEach(model.recent) { meeting in
                    HStack {
                        Button(meeting.id) { model.open(meeting) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.reveal(meeting)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()
            HStack {
                Text("Папка встреч: \(model.outputDirDisplay)").font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Изменить…") { model.chooseOutputDir() }
            }
            Picker("Саммари:", selection: Binding(get: { model.summaryChoice }, set: { model.setSummary($0) })) {
                Text("Claude").tag("claude")
                Text("ChatGPT").tag("codex")
                Text("Выкл").tag("off")
            }
            .pickerStyle(.segmented)
            if let hint = model.summaryHint {
                WarningText(text: hint)
            }
            HStack {
                Toggle("Автообновление", isOn: Binding(get: { model.autoUpdate }, set: { model.setAutoUpdate($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Text("Версия \(model.appVersion)").font(.caption).foregroundStyle(.secondary)
                Button("Проверить") { model.checkForUpdates() }
                    .disabled(!model.canStartUpdate)
            }
            if let available = model.updateAvailable, !model.autoUpdate {
                HStack {
                    Text("Доступна версия \(available)").font(.caption)
                    Spacer()
                    Button("Обновить") { model.installAvailableUpdate() }
                        .disabled(!model.canStartUpdate)
                }
            }
            if let status = model.updateStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let note = model.updateNote {
                WarningText(text: note)
            }
            HStack {
                Button("Открыть папку встреч") { model.openOutputFolder() }
                Spacer()
                Button("Выход") { appDelegate?.quitRequested() }
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

struct LevelRow: View {
    let name: String
    let db: Float
    let silent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.caption).frame(width: 70, alignment: .leading)
                ProgressView(value: Double(min(0, max(-60, db)) + 60), total: 60)
                Text("\(Int(db)) dB").font(.caption2).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            if silent {
                WarningText(text: "Нет сигнала", tint: .red)
            }
        }
    }
}

struct WarningText: View {
    let text: String
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint)
            Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }
}
