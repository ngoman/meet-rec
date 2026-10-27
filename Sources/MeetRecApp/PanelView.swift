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
                Text(message).font(.caption).foregroundStyle(.orange)
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
                                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
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
                    Text("и ещё \(model.pending.count - 8)").font(.caption2).foregroundStyle(.secondary)
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
            Toggle("Саммари через Claude", isOn: Binding(get: { model.summaryEnabled }, set: { model.setSummary($0) }))
            HStack {
                Button("Открыть папку встреч") { model.openOutputFolder() }
                Spacer()
                Button("Выход") { model.quit() }
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
                Text("Нет сигнала").font(.caption2).fontWeight(.medium).foregroundStyle(.red)
            }
        }
    }
}
