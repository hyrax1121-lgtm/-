import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct SettingsView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var backup: BackupService
    @ObservedObject var reminders: ReminderService
    @State private var reminderEnabled = false
    @State private var reminderTime = Date()
    @State private var isApplyingReminder = false
    @State private var pickerMode: PickerMode = .backupFolder
    @State private var showPicker = false
    @State private var preview: ImportPreview?
    @State private var confirmingImport = false
    @State private var confirmingDelete = false
    @State private var message: String?
    @State private var shareURL: URL?
    @State private var isSharing = false
    private enum PickerMode { case backupFolder, restore }

    var body: some View {
        Form {
            Section {
                Label("记录保存在这台 iPhone", systemImage: "iphone.gen3")
                Notice(text: "没有账号，也不上传日记到应用服务器。语音只尝试本机识别；选择 iCloud Drive 作为备份位置时，备份由系统保存到你的 iCloud。")
            }
            Section("晚间提醒") {
                Toggle("启用提醒", isOn: $reminderEnabled)
                if reminderEnabled {
                    DatePicker("提醒时间", selection: $reminderTime, displayedComponents: .hourAndMinute)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                }
                Button(isApplyingReminder ? "正在应用…" : "应用提醒设置") { applyReminder() }.disabled(isApplyingReminder)
                Notice(text: reminders.statusText)
                Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            } footer: {
                Text("锁屏通知只显示中性提醒，不显示日记内容或人物。想休息时可以关闭；iOS 无法可靠告诉应用你是否忽略了提醒，因此本版不自动判断或催促。")
            }
            Section("完整备份") {
                Button("选择备份文件夹") { pickerMode = .backupFolder; showPicker = true }
                LabeledContent("当前位置", value: backup.selectedFolderName ?? "尚未选择")
                if let date = backup.lastSuccessfulBackupAt {
                    LabeledContent("最近成功", value: date.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN"))))
                }
                Toggle("定期备份", isOn: Binding(get: { store.settings.automaticBackupEnabled }, set: { enabled in
                    var settings = store.settings; settings.automaticBackupEnabled = enabled; saveSettings(settings)
                    if enabled { Task { await backup.backupIfDue() } }
                }))
                Stepper("每 \(store.settings.backupIntervalDays) 天检查一次", value: Binding(get: { store.settings.backupIntervalDays }, set: { days in
                    var settings = store.settings; settings.backupIntervalDays = days; saveSettings(settings)
                }), in: 1...30)
                Button("立即创建完整备份") {
                    do { let url = try backup.backupNow(); message = "完整备份已保存：\(url.lastPathComponent)" }
                    catch { message = error.localizedDescription }
                }
                Notice(text: backup.statusText)
            } footer: {
                Text("完整备份是包含 JSON、逐日 Markdown 和录音附件的文件夹。可选择「我的 iPhone」或 iCloud Drive。系统后台执行由 iOS 决定，不保证准时；打开 App 时会检查并补做。备份成功时间以实际完成为准。")
            }
            Section("导出与恢复") {
                Button("导出 JSON") { exportJSON() }
                Button("导出 Markdown") { exportMarkdown() }
                Button("从备份恢复") { pickerMode = .restore; showPicker = true }
                Notice(text: "JSON 和 Markdown 单文件用于迁移或阅读，不包含录音实体。要恢复录音，请选择完整备份文件夹。导入前会显示预览，同一编号内容不同会保留副本。")
            }
            Section {
                Button("删除全部本地数据", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("会删除 App 内所有记录、转写原文、录音、速记草稿与临时导出文件。你在「文件」或 iCloud Drive 中保存的备份不会自动删除。")
            }
            Section("关于") {
                LabeledContent("版本", value: "0.3 · 自用版")
                Notice(text: "写多少都可以，中断后随时回来。没有打卡、连续天数或徽章。照片、AI 和跨设备同步尚未加入。")
            }
        }
        .navigationTitle("设置")
        .onAppear { loadReminderSettings() }
        .onChange(of: store.settings) { _, _ in loadReminderSettings() }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: pickerMode == .backupFolder ? [.folder] : [.folder, .json], allowsMultipleSelection: false) { result in
            handlePicker(result)
        }
        .confirmationDialog("恢复这份备份？", isPresented: $confirmingImport, titleVisibility: .visible) {
            Button("合并恢复") { restore() }
            Button("取消", role: .cancel) { preview = nil }
        } message: { Text(preview?.summaryText ?? "") }
        .confirmationDialog("删除全部本地数据？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除全部记录、录音与草稿", role: .destructive) {
                do {
                    try store.deleteAll()
                    var settings = store.settings
                    settings.reminderEnabled = false
                    try store.updateSettings(settings)
                    reminders.removeAll()
                    message = "本地记录、录音、草稿和临时导出文件已删除。外部备份仍由你管理。"
                } catch { message = error.localizedDescription }
            }
        } message: { Text("删除后无法在 App 内撤销。外部备份需要你另行删除；如需保留，请先完成备份。") }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .sheet(isPresented: $isSharing) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
    }

    private func loadReminderSettings() {
        reminderEnabled = store.settings.reminderEnabled
        let parts = store.settings.reminderTime.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2, let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) { reminderTime = date }
    }
    private func saveSettings(_ settings: DiarySettings) {
        do { try store.updateSettings(settings) } catch { message = error.localizedDescription }
    }
    private func applyReminder() {
        isApplyingReminder = true
        let components = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        let time = String(format: "%02d:%02d", components.hour ?? 21, components.minute ?? 0)
        let enabled = reminderEnabled
        Task {
            defer { isApplyingReminder = false }
            let previous = store.settings
            do {
                try await reminders.apply(enabled: enabled, time: time)
                var settings = previous; settings.reminderEnabled = enabled; settings.reminderTime = time
                do { try store.updateSettings(settings) }
                catch {
                    try? await reminders.apply(enabled: previous.reminderEnabled, time: previous.reminderTime)
                    throw error
                }
                message = enabled ? "晚间提醒已设置。" : "晚间提醒已关闭。"
            } catch { message = error.localizedDescription }
        }
    }
    private func handlePicker(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            if pickerMode == .backupFolder {
                try backup.chooseFolder(url: url)
                Task { await backup.backupIfDue() }
            } else {
                preview = try backup.prepareImport(from: url)
                confirmingImport = true
            }
        } catch { message = error.localizedDescription }
    }
    private func restore() {
        guard let preview else { return }
        do {
            let report = try backup.restore(preview)
            self.preview = nil
            message = report.summaryText
            loadReminderSettings()
            // Restoring an enabled preference must not silently prompt for a new
            // notification permission. The user applies it in the reminder section.
            reminders.removeAll()
            if store.settings.reminderEnabled {
                message = report.summaryText + "\n如需开启提醒，请在本页点击「应用提醒设置」。"
            }
        } catch { message = error.localizedDescription }
    }
    private func exportJSON() {
        do { shareURL = try backup.exportRecordsJSON(); isSharing = true }
        catch { message = error.localizedDescription }
    }
    private func exportMarkdown() {
        do { shareURL = try backup.exportMarkdown(); isSharing = true }
        catch { message = error.localizedDescription }
    }
}

@MainActor
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
