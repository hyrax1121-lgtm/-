import SwiftUI

@MainActor
struct RootView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var backup: BackupService
    @StateObject private var voice = VoiceService()
    @StateObject private var reminders = ReminderService()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    @State private var errorMessage: String?

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { CaptureView(store: store, voice: voice) }
                .tabItem { Label("速记", systemImage: "square.and.pencil") }.tag(0)
            NavigationStack { TodayView(store: store, voice: voice) }
                .tabItem { Label("今天", systemImage: "sun.max") }.tag(1)
            NavigationStack { ReviewView(store: store, voice: voice) }
                .tabItem { Label("回看", systemImage: "book") }.tag(2)
            NavigationStack { SettingsView(store: store, backup: backup, reminders: reminders) }
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(3)
        }
        .overlay {
            if scenePhase != .active {
                ZStack {
                    Palette.paper.ignoresSafeArea()
                    Label("三件事日记", systemImage: "book.closed").font(.title2).foregroundStyle(Palette.ink)
                }
                .accessibilityHidden(true)
            }
        }
        .task {
            configureVoiceCapture()
            recoverUnlinkedRecordings()
            await reminders.refresh()
            await backup.backupIfDue()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await reminders.refresh(); await backup.backupIfDue() }
            } else if phase == .background {
                voice.stopRecording()
                voice.stopPlayback()
                BackupScheduler.shared.schedule()
            } else if phase == .inactive {
                voice.stopRecording()
            }
        }
        .alert("未能完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func recoverUnlinkedRecordings() {
        do {
            let referenced = Set(store.entries.compactMap(\.audioFilename))
            let files = try FileManager.default.contentsOfDirectory(at: AppPaths.audioDirectory, includingPropertiesForKeys: [.fileSizeKey])
            var recovered = 0
            for file in files where file.pathExtension.lowercased() == "m4a" && !referenced.contains(file.lastPathComponent) {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else { continue }
                var snapshot = EntrySnapshot()
                snapshot.inputMethod = "voice"
                snapshot.audioFilename = file.lastPathComponent
                snapshot.captureOrigin = true
                _ = try store.add(snapshot: snapshot)
                recovered += 1
            }
            if recovered > 0 { errorMessage = "找回 \(recovered) 段未关联的录音，已放入今天的未分类记录。显示时间为找回时间；可以打开回听、补记日期或重试转写。" }
        } catch { errorMessage = "部分未关联录音暂时无法写入记录，音频仍保留在本机。请保留 App 并重新打开重试：\(error.localizedDescription)" }
    }

    private func configureVoiceCapture() {
        voice.onRecordingSaved = { filename in
            do {
                var snapshot = EntrySnapshot()
                snapshot.date = DisplayDate.key(Date())
                snapshot.type = "unsorted"
                snapshot.inputMethod = "voice"
                snapshot.audioFilename = filename
                snapshot.captureOrigin = true
                let saved = try store.add(snapshot: snapshot)
                let id = saved.id
                Task {
                    do {
                        let text = try await voice.transcribe(filename: filename)
                        guard let entry = store.entries.first(where: { $0.id == id }) else { return }
                        var current = store.snapshot(for: entry)
                        // Preserve edits made while recognition was in progress.
                        if current.transcriptRaw == nil { current.transcriptRaw = text }
                        if current.content.isEmpty { current.content = text }
                        try store.update(entry: entry, using: current)
                    } catch {
                        // Audio-only entry has already committed to the database.
                    }
                }
            } catch {
                errorMessage = "录音文件已保留，但记录未能保存：\(error.localizedDescription)。请保留 App，重新打开后会尝试找回未关联录音。"
            }
        }
    }
}
