import Foundation
import Combine
import SwiftData

struct DiarySettings: Codable, Equatable {
    var reminderEnabled = false
    var reminderTime = "21:00"
    var automaticBackupEnabled = true
    var backupIntervalDays = 7

    enum CodingKeys: String, CodingKey {
        case reminderEnabled = "remind", reminderTime = "time"
        case automaticBackupEnabled = "automatic_backup_enabled"
        case backupIntervalDays = "backup_interval_days"
        case oldReminderEnabled = "reminder_enabled", oldReminderTime = "reminder_time"
        case oldAutomaticBackupEnabled = "auto_backup_enabled"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reminderEnabled = try c.decodeIfPresent(Bool.self, forKey: .reminderEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .oldReminderEnabled) ?? false
        reminderTime = try c.decodeIfPresent(String.self, forKey: .reminderTime)
            ?? c.decodeIfPresent(String.self, forKey: .oldReminderTime) ?? "21:00"
        automaticBackupEnabled = try c.decodeIfPresent(Bool.self, forKey: .automaticBackupEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .oldAutomaticBackupEnabled) ?? true
        backupIntervalDays = try c.decodeIfPresent(Int.self, forKey: .backupIntervalDays) ?? 7
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reminderEnabled, forKey: .reminderEnabled)
        try c.encode(reminderTime, forKey: .reminderTime)
        try c.encode(automaticBackupEnabled, forKey: .automaticBackupEnabled)
        try c.encode(backupIntervalDays, forKey: .backupIntervalDays)
    }

    func validate() throws {
        let parts = reminderTime.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute),
              (1...365).contains(backupIntervalDays) else {
            throw DiaryError.invalidBackup("提醒时间或备份间隔无效。")
        }
    }
}

@MainActor
final class DiaryStore: ObservableObject {
    let container: ModelContainer
    let context: ModelContext
    @Published private(set) var entries: [DiaryEntry] = []
    @Published private(set) var settings: DiarySettings

    init(inMemory: Bool = false) throws {
        try AppPaths.ensureDirectories()
        let schema = Schema([DiaryEntry.self])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            config = ModelConfiguration(schema: schema, url: AppPaths.database, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        context.autosaveEnabled = false
        if FileManager.default.fileExists(atPath: AppPaths.settingsFile.path) {
            settings = try BackupJSON.decoder().decode(DiarySettings.self, from: Data(contentsOf: AppPaths.settingsFile))
        } else { settings = DiarySettings() }
        try recoverPendingDeletions()
        try reload()
        // Share copies from earlier sessions are temporary, not an additional diary.
        for file in (try? FileManager.default.contentsOfDirectory(at: AppPaths.exportsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func reload() throws {
        entries = try context.fetch(FetchDescriptor<DiaryEntry>(sortBy: [SortDescriptor(\DiaryEntry.createdAt)]))
    }

    func snapshot(for entry: DiaryEntry) -> EntrySnapshot {
        EntrySnapshot(id: entry.id, date: entry.date, createdAt: entry.createdAt,
                      updatedAt: entry.updatedAt, type: entry.type, inputMethod: entry.inputMethod,
                      content: entry.content, transcriptRaw: entry.transcriptRaw,
                      audioFilename: entry.audioFilename, missingAudioRef: entry.missingAudioRef,
                      originalAudioRef: entry.originalAudioRef, basis: entry.basis,
                      prediction: entry.prediction, confidence: entry.confidence,
                      speaker: entry.speaker, certainty: entry.certainty, myReaction: entry.myReaction,
                      isBackfilled: entry.isBackfilled, hideFromResurface: entry.hideFromResurface,
                      captureOrigin: entry.captureOrigin, conflictOf: entry.conflictOf,
                      restoredAt: entry.restoredAt, conflictSource: entry.conflictSource)
    }

    @discardableResult
    func add(snapshot: EntrySnapshot) throws -> DiaryEntry {
        try snapshot.validate()
        guard !entries.contains(where: { $0.id == snapshot.id }) else {
            throw DiaryError.io("这条记录的编号已存在，请使用编辑或恢复功能。")
        }
        let entry = DiaryEntry(snapshot: snapshot)
        context.insert(entry)
        try commit()
        return entry
    }

    func update(entry: DiaryEntry, using snapshot: EntrySnapshot) throws {
        try snapshot.validate()
        guard entry.id == snapshot.id, entries.contains(where: { $0.id == entry.id }) else { throw DiaryError.missingEntry }
        // The original transcript is write-once. Corrections belong in content.
        if let original = entry.transcriptRaw, snapshot.transcriptRaw != original {
            throw DiaryError.io("转写原文不能修改，请在正文中校对。")
        }
        var edited = snapshot
        edited.updatedAt = Date()
        let previousAudio = entry.audioFilename
        let removedAudio = previousAudio != snapshot.audioFilename
            ? unusedAudioFiles([previousAudio].compactMap { $0 }, excluding: [entry.id]) : []
        try performDeletionTransaction(audio: removedAudio, removeDraft: false) {
            entry.apply(edited)
        }
    }

    @discardableResult
    func upsert(_ snapshot: EntrySnapshot) throws -> DiaryEntry {
        if let entry = entries.first(where: { $0.id == snapshot.id }) {
            try update(entry: entry, using: snapshot)
            return entry
        }
        return try add(snapshot: snapshot)
    }

    func delete(id: UUID) throws {
        guard let entry = entries.first(where: { $0.id == id }) else { throw DiaryError.missingEntry }
        let audio = unusedAudioFiles([entry.audioFilename].compactMap { $0 }, excluding: [id])
        try performDeletionTransaction(audio: audio, removeDraft: false) { context.delete(entry) }
    }

    func deleteEntry(id: UUID) throws { try delete(id: id) }

    /// Also removes an unsaved text draft, orphaned audio, and temporary share copies.
    /// External user-owned backup folders are intentionally not erased.
    func deleteAll() throws {
        let files = try FileManager.default.contentsOfDirectory(at: AppPaths.audioDirectory, includingPropertiesForKeys: nil)
        try performDeletionTransaction(audio: files, removeDraft: true, removeExports: true) {
            for entry in entries { context.delete(entry) }
        }
    }

    func updateSettings(_ value: DiarySettings) throws {
        try value.validate()
        try BackupJSON.encoder().encode(value).write(to: AppPaths.settingsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        settings = value
    }

    func saveDraft(_ text: String) throws {
        if text.isEmpty { try clearDraft(); return }
        try Data(text.utf8).write(to: AppPaths.draftFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadDraft() -> String {
        (try? String(contentsOf: AppPaths.draftFile, encoding: .utf8)) ?? ""
    }

    func clearDraft() throws {
        if FileManager.default.fileExists(atPath: AppPaths.draftFile.path) {
            try FileManager.default.removeItem(at: AppPaths.draftFile)
        }
    }

    /// Inserts a prepared import as one SwiftData save. No user text is changed.
    /// Callers stage new attachments before invoking this and remove them on failure.
    func insertImported(_ snapshots: [EntrySnapshot], settings importedSettings: DiarySettings?, updating updates: [EntrySnapshot] = []) throws {
        for item in snapshots { try item.validate() }
        for item in updates { try item.validate() }
        let ids = snapshots.map(\.id)
        guard Set(ids).count == ids.count, !entries.contains(where: { ids.contains($0.id) }) else {
            throw DiaryError.invalidBackup("导入编号冲突，请重新预览备份。")
        }
        for value in updates {
            guard let old = entries.first(where: { $0.id == value.id }),
                  old.transcriptRaw == value.transcriptRaw else { throw DiaryError.invalidBackup("待恢复录音的记录已改变，请重新预览。") }
        }
        if let importedSettings { try importedSettings.validate() }
        let oldSettingsData = try? Data(contentsOf: AppPaths.settingsFile)
        do {
            // Prepare the settings file before saving the database; restore it if save fails.
            if let importedSettings {
                try BackupJSON.encoder().encode(importedSettings).write(to: AppPaths.settingsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            for snapshot in snapshots { context.insert(DiaryEntry(snapshot: snapshot)) }
            for value in updates { entries.first(where: { $0.id == value.id })?.apply(value) }
            try context.save()
        } catch {
            context.rollback()
            if importedSettings != nil {
                do {
                    if let oldSettingsData { try oldSettingsData.write(to: AppPaths.settingsFile, options: .atomic) }
                    else if FileManager.default.fileExists(atPath: AppPaths.settingsFile.path) { try FileManager.default.removeItem(at: AppPaths.settingsFile) }
                } catch { throw DiaryError.rollbackFailed(error.localizedDescription) }
            }
            try? reload()
            throw error
        }
        if let importedSettings { settings = importedSettings }
        try reload()
    }

    private func commit() throws {
        do { try context.save() }
        catch { context.rollback(); try? reload(); throw error }
        try reload()
    }

    private func unusedAudioFiles(_ names: [String], excluding ids: Set<UUID>) -> [URL] {
        names.compactMap { name in
            guard !entries.contains(where: { !ids.contains($0.id) && $0.audioFilename == name }) else { return nil }
            return try? AppPaths.audioURL(filename: name)
        }
    }

    private struct FileMove: Codable {
        var location: String
        var name: String
        var staged: String
    }
    private struct DeletionJournal: Codable {
        var phase: String
        var before: [EntrySnapshot]
        var moves: [FileMove]
    }

    private func originalURL(for move: FileMove) throws -> URL {
        guard AppPaths.isSafeFilename(move.staged), !move.name.hasPrefix("/"),
              !move.name.contains("\\"), !move.name.split(separator: "/").contains("..") else {
            throw DiaryError.io("删除恢复日志的路径无效，已停止操作以保留原文件。")
        }
        let base: URL
        switch move.location {
        case "root": base = AppPaths.root
        case "exports": base = AppPaths.exportsDirectory
        default: throw DiaryError.io("删除恢复日志的目录无效。")
        }
        let result = base.appendingPathComponent(move.name).standardizedFileURL
        guard result.path.hasPrefix(base.standardizedFileURL.path + "/") else {
            throw DiaryError.io("删除恢复日志超出了应用目录。")
        }
        return result
    }

    private func restoreRows(_ snapshots: [EntrySnapshot]) throws {
        let current = try context.fetch(FetchDescriptor<DiaryEntry>())
        let ids = Set(snapshots.map(\.id))
        for entry in current where !ids.contains(entry.id) { context.delete(entry) }
        for value in snapshots {
            if let entry = current.first(where: { $0.id == value.id }) { entry.apply(value) }
            else { context.insert(DiaryEntry(snapshot: value)) }
        }
        try context.save()
    }

    /// Before the commit marker a killed operation is rolled back on next launch.
    /// After that marker, only already-deleted attachment copies are cleaned up.
    private func recoverPendingDeletions() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: AppPaths.recoveryDirectory.path) else { return }
        for folder in try fm.contentsOfDirectory(at: AppPaths.recoveryDirectory, includingPropertiesForKeys: nil) {
            let journalURL = folder.appendingPathComponent("journal.json")
            guard fm.fileExists(atPath: journalURL.path) else {
                if try fm.contentsOfDirectory(atPath: folder.path).isEmpty { try fm.removeItem(at: folder); continue }
                throw DiaryError.io("发现旧的附件恢复目录。请保留应用数据，暂勿继续删除。")
            }
            let journal = try BackupJSON.decoder().decode(DeletionJournal.self, from: Data(contentsOf: journalURL))
            if journal.phase == "prepared" {
                for move in journal.moves {
                    let original = try originalURL(for: move)
                    let staged = folder.appendingPathComponent(move.staged)
                    if fm.fileExists(atPath: staged.path) {
                        if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
                        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: staged, to: original)
                    } else if !fm.fileExists(atPath: original.path) {
                        throw DiaryError.rollbackFailed("附件恢复文件缺失：\(move.name)")
                    }
                }
                try restoreRows(journal.before)
            } else if journal.phase != "committed" {
                throw DiaryError.io("无法识别删除恢复状态，原文件已保留。")
            }
            try fm.removeItem(at: folder)
        }
    }

    private func performDeletionTransaction(audio: [URL], removeDraft: Bool,
                                            removeExports: Bool = false, mutation: () throws -> Void) throws {
        let fm = FileManager.default
        var targets = audio
        if removeDraft { targets.append(AppPaths.draftFile) }
        if removeExports { targets += try fm.contentsOfDirectory(at: AppPaths.exportsDirectory, includingPropertiesForKeys: nil) }
        targets = Array(Set(targets)).filter { fm.fileExists(atPath: $0.path) }
        if targets.isEmpty {
            do { try mutation(); try context.save(); try reload(); return }
            catch { context.rollback(); try? reload(); throw error }
        }
        let transaction = AppPaths.recoveryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let before = entries.map { snapshot(for: $0) }
        let root = AppPaths.root.standardizedFileURL.path + "/"
        let exports = AppPaths.exportsDirectory.standardizedFileURL.path + "/"
        let moves: [FileMove] = try targets.map { file in
            let path = file.standardizedFileURL.path
            if path.hasPrefix(exports) { return FileMove(location: "exports", name: String(path.dropFirst(exports.count)), staged: UUID().uuidString) }
            guard path.hasPrefix(root) else { throw DiaryError.io("拒绝删除应用目录外的文件。") }
            return FileMove(location: "root", name: String(path.dropFirst(root.count)), staged: UUID().uuidString)
        }
        var journal = DeletionJournal(phase: "prepared", before: before, moves: moves)
        var saved = false
        try fm.createDirectory(at: transaction, withIntermediateDirectories: true)
        let journalURL = transaction.appendingPathComponent("journal.json")
        do {
            try BackupJSON.encoder().encode(journal).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            for move in moves {
                let original = try originalURL(for: move)
                try fm.moveItem(at: original, to: transaction.appendingPathComponent(move.staged))
            }
            try mutation()
            try context.save()
            saved = true
            journal.phase = "committed"
            try BackupJSON.encoder().encode(journal).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            context.rollback()
            do {
                for move in moves {
                    let original = try originalURL(for: move)
                    let staged = transaction.appendingPathComponent(move.staged)
                    if fm.fileExists(atPath: staged.path), !fm.fileExists(atPath: original.path) { try fm.moveItem(at: staged, to: original) }
                }
                if saved { try restoreRows(before) }
                try fm.removeItem(at: transaction)
                try reload()
            } catch { throw DiaryError.rollbackFailed(error.localizedDescription) }
            throw error
        }
        do { try fm.removeItem(at: transaction) }
        catch {
            // The database commit is durable. Keep a committed journal so the next
            // launch can finish removing any remaining staged copies.
            try reload()
            throw DiaryError.io("记录已删除，但部分临时附件尚未清理。请重新打开 App 完成清理。")
        }
        try reload()
    }
}
