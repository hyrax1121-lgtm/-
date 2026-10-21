import SwiftUI

@MainActor
struct CaptureView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var voice: VoiceService
    @State private var text = ""
    @State private var saveMessage = ""
    @State private var errorMessage: String?
    @State private var editing: DiaryEntry?
    @FocusState private var focused: Bool
    @State private var gestureActive = false

    private var recentEntries: [DiaryEntry] {
        store.entries.filter { $0.date == DisplayDate.key(Date()) && $0.captureOrigin }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("先记下来，一句话也可以。")
                    .font(.title3).foregroundStyle(Palette.muted)
                PaperCard {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty { Text("此刻有什么想留下？").foregroundStyle(Palette.muted).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                        TextEditor(text: $text)
                            .frame(minHeight: 170).scrollContentBackground(.hidden)
                            .focused($focused).font(.system(size: 18))
                            .accessibilityLabel("速记内容")
                    }
                    HStack {
                        Text(saveMessage).font(.footnote).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("保存") { saveText() }
                            .buttonStyle(.borderedProminent)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if !recentEntries.isEmpty {
                    Text("今天的速记").font(.headline)
                    ForEach(recentEntries) { entry in
                        Button { editing = entry; focused = false } label: {
                            PaperCard { EntryRow(entry: entry) }
                        }.buttonStyle(.plain)
                    }
                }
                Notice(text: "不用一次写完。稍后可以到「今天」整理分类，也可以就这样留着。")
            }.padding(20)
        }
        .background(Palette.paper)
        .navigationTitle("速记")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起键盘") { focused = false }
            }
        }
        .safeAreaInset(edge: .bottom) { voiceBar }
        .onAppear { text = store.loadDraft() }
        .onChange(of: text) { _, value in
            do { try store.saveDraft(value) }
            catch { saveMessage = "草稿未能自动保存，请保留页面并点击保存。" }
            if saveMessage == "已保存" && !value.isEmpty { saveMessage = "" }
        }
        .onDisappear { voice.stopRecording(); gestureActive = false }
        .sheet(item: $editing) { entry in
            EntryEditorView(store: store, voice: voice, entry: entry)
        }
        .alert("未能保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var voiceBar: some View {
        VStack(spacing: 8) {
            Notice(text: voice.message).multilineTextAlignment(.center).frame(maxWidth: 420)
            if voice.microphoneReady {
                Circle()
                    .fill(voice.isRecording ? Color.red.opacity(0.85) : Palette.ink)
                    .overlay {
                        if voice.isTranscribing { ProgressView().tint(.white) }
                        else { Image(systemName: voice.isRecording ? "waveform" : "mic.fill").font(.system(size: 27)).foregroundStyle(.white) }
                    }
                    .frame(width: 70, height: 70)
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !gestureActive else { return }
                            gestureActive = true
                            focused = false
                            voice.startRecording()
                        }
                        .onEnded { _ in gestureActive = false; voice.stopRecording() })
                    .accessibilityElement()
                    .accessibilityLabel(voice.isRecording ? "停止录音并保存" : "按住录音")
                    .accessibilityHint("松开后保存录音并尝试中文离线转写。使用旁白时双击开始，再双击停止。")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        if voice.isRecording { voice.stopRecording() }
                        else { voice.startRecording() }
                    }
                    .opacity(voice.isTranscribing ? 0.55 : 1)
                Text(voice.isRecording ? "松开保存" : "按住说话").font(.caption).foregroundStyle(Palette.muted)
            } else {
                Button {
                    focused = false
                    Task { await voice.prepare() }
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            Circle().fill(Palette.ink).frame(width: 70, height: 70)
                            if voice.isPreparing { ProgressView().tint(.white) }
                            else { Image(systemName: "mic.fill").font(.system(size: 27)).foregroundStyle(.white) }
                        }
                        Text("启用语音").font(.caption).foregroundStyle(Palette.muted)
                    }
                }.disabled(voice.isPreparing)
            }
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private func saveText() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            var snapshot = EntrySnapshot()
            snapshot.date = DisplayDate.key(Date())
            snapshot.type = "unsorted"
            snapshot.content = text
            snapshot.captureOrigin = true
            _ = try store.add(snapshot: snapshot)
            text = ""
            try store.clearDraft()
            saveMessage = "已保存"
        } catch { errorMessage = error.localizedDescription }
    }
}
