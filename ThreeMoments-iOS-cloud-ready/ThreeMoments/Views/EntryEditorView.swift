import SwiftUI

@MainActor
struct EntryEditorView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var voice: VoiceService
    let entry: DiaryEntry?
    @State private var draft: EntrySnapshot
    @State private var selectedDate: Date
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var isRetrying = false
    @Environment(\.dismiss) private var dismiss

    init(store: DiaryStore, voice: VoiceService, entry: DiaryEntry? = nil, date: String? = nil, type: String = "unsorted") {
        self.store = store
        self.voice = voice
        self.entry = entry
        var snapshot = entry.map { store.snapshot(for: $0) } ?? EntrySnapshot()
        if entry == nil {
            snapshot.date = date ?? DisplayDate.key(Date())
            snapshot.type = type
            snapshot.isBackfilled = snapshot.date != DisplayDate.key(Date())
            snapshot.captureOrigin = false
        }
        _draft = State(initialValue: snapshot)
        _selectedDate = State(initialValue: DisplayDate.date(snapshot.date))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("记录日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    Picker("分类", selection: $draft.type) {
                        ForEach(EntryKind.allCases) { kind in Text(kind.title).tag(kind.rawValue) }
                    }
                    Toggle("补记", isOn: $draft.isBackfilled)
                } footer: { Text("补记会单独标明，记录日期与实际创建时间分别保留。") }

                Section(draft.inputMethod == "voice" ? "校对后的文字" : "内容") {
                    TextEditor(text: $draft.content).frame(minHeight: 190).font(.system(size: 18))
                        .accessibilityLabel(draft.inputMethod == "voice" ? "可编辑的校对文字" : "记录内容")
                }

                if draft.type == "thought" { thoughtFields }
                if draft.type == "quote" { quoteFields }

                if let filename = draft.audioFilename {
                    Section("录音") {
                        HStack {
                            Button { voice.play(filename: filename) } label: { Label("听原始录音", systemImage: "play.fill") }
                            Spacer()
                            Button { voice.stopPlayback() } label: { Image(systemName: "stop.fill") }.accessibilityLabel("停止播放")
                        }
                        if draft.transcriptRaw == nil {
                            Button(isRetrying ? "正在本机转写…" : "重试本机转写") { retryTranscription(filename) }
                                .disabled(isRetrying || voice.isTranscribing)
                            Notice(text: "中文离线转写不可用时会保留录音，不会自动发送到网络识别。")
                        }
                    }
                }

                if let raw = draft.transcriptRaw {
                    Section("转写原文 · 只读") {
                        Text(raw).font(.system(size: 17)).textSelection(.enabled)
                    } footer: { Text("校对不会改动这份原文。删除整条记录时，原文和录音也会一并删除。") }
                }

                Section {
                    Toggle("不主动展示", isOn: $draft.hideFromResurface)
                } footer: { Text("这条记录仍可手动查看与搜索。以后加入回顾推荐时，不会主动推送它。") }

                if entry != nil {
                    Section {
                        Button("删除这条记录", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(entry == nil ? (draft.isBackfilled ? "补记" : "留下一件事") : "编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(!canSave) }
            }
            .confirmationDialog("删除这条记录？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除记录及录音", role: .destructive) { delete() }
            } message: { Text("App 内会删除文字、转写原文和录音。已导出的备份需由你另行管理。") }
            .alert("未能完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onChange(of: selectedDate) { _, date in
                draft.date = DisplayDate.key(date)
                if draft.date != DisplayDate.key(Date()) { draft.isBackfilled = true }
            }
            .onDisappear { voice.stopPlayback() }
        }
    }

    private var canSave: Bool {
        !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (draft.inputMethod == "voice" && (draft.audioFilename != nil || draft.missingAudioRef != nil || !(draft.transcriptRaw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    private var thoughtFields: some View {
        Group {
            Section("当时的依据") {
                TextField("为什么会这样想？可以留空。", text: optionalString(\.basis), axis: .vertical).lineLimit(3...6)
            }
            Section("判断 · 可选") {
                TextField("你觉得接下来会怎样？", text: optionalString(\.prediction), axis: .vertical).lineLimit(2...5)
                Toggle("记录把握程度", isOn: Binding(get: { draft.confidence != nil }, set: { draft.confidence = $0 ? 50 : nil }))
                if draft.confidence != nil {
                    Slider(value: Binding(get: { Double(draft.confidence ?? 50) }, set: { draft.confidence = Int($0) }), in: 0...100, step: 5)
                        .accessibilityLabel("把握程度")
                    Text("当时的把握：\(draft.confidence ?? 50)%").font(.footnote).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private var quoteFields: some View {
        Section("说话时的上下文") {
            TextField("是谁说的？", text: optionalString(\.speaker))
            Picker("记下的是", selection: optionalString(\.certainty)) {
                Text("未标注").tag("")
                Text("原话").tag("verbatim")
                Text("大意").tag("gist")
            }
            TextField("当时听到的感受或反应", text: optionalString(\.myReaction), axis: .vertical).lineLimit(3...6)
        }
    }

    private func optionalString(_ path: WritableKeyPath<EntrySnapshot, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: path] ?? "" }, set: { draft[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        do {
            draft.date = DisplayDate.key(selectedDate)
            if let entry {
                // A recording may finish transcribing while its editor is open.
                // Merge that write-once original into the editable draft.
                draft.transcriptRaw = entry.transcriptRaw ?? draft.transcriptRaw
                try store.update(entry: entry, using: draft)
            }
            else { _ = try store.add(snapshot: draft) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func delete() {
        guard let entry else { return }
        do { voice.stopPlayback(); try store.delete(id: entry.id); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }

    private func retryTranscription(_ filename: String) {
        isRetrying = true
        Task {
            defer { isRetrying = false }
            // A retry is a deliberate tap; requesting permissions here cannot
            // unexpectedly start microphone recording after a released gesture.
            await voice.authorizeTranscription()
            do {
                let raw = try await voice.transcribe(filename: filename)
                draft.transcriptRaw = raw
                if draft.content.isEmpty { draft.content = raw }
                if let entry {
                    var persisted = store.snapshot(for: entry)
                    if persisted.transcriptRaw == nil {
                        persisted.transcriptRaw = raw
                        if persisted.content.isEmpty { persisted.content = raw }
                        try store.update(entry: entry, using: persisted)
                    }
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
