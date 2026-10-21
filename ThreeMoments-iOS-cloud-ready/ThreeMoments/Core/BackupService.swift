import Foundation
import Combine
import CryptoKit

struct BackupDocument: Codable {
    var format = "three-moments"
    var version = 1
    var entries: [EntrySnapshot]
    var settings: DiarySettings?
    var exportedAt: Date?
    var backupKind: String?
    var audioAttachments: [String: String]?
    var audioSHA256: [String: String]?

    enum CodingKeys: String, CodingKey {
        case format, version, entries, settings
        case exportedAt = "exported_at", backupKind = "backup_kind"
        case audioAttachments = "audio_attachments", audioSHA256 = "audio_sha256"
    }

    func validate() throws {
        guard format == "three-moments", version == 1 else {
            throw DiaryError.invalidBackup("备份格式或版本无法识别。")
        }
        guard Set(entries.map(\.id)).count == entries.count else {
            throw DiaryError.invalidBackup("文件中有重复编号，请先检查备份。")
        }
        for entry in entries { try entry.validate() }
        try settings?.validate()
    }
}

struct ImportPreview: Identifiable {
    let id = UUID()
    let document: BackupDocument
    let sourceName: String
    let missingAudioCount: Int
    fileprivate let audioData: [String: Data]

    var summaryText: String {
        var text = "将读取 \(document.entries.count) 条记录。同编号的不同版本会另存为冲突副本，原记录和原文都会保留。"
        if document.settings != nil { text += "提醒时间和备份间隔也会恢复。" }
        if missingAudioCount > 0 {
            text += "\n\n这个备份未包含 \(missingAudioCount) 个录音附件，只能恢复对应文字和转写原文；附件引用仍会保留，之后可用完整文件夹补回。"
        } else if !audioData.isEmpty { text += "\n\n已检查 \(audioData.count) 个录音附件，可以完整恢复。" }
        return text
    }
}

struct ImportReport {
    var added = 0
    var conflicts = 0
    var skipped = 0
    var repairedAudio = 0
    var settingsRestored = false
    var missingAudio = 0

    var summaryText: String {
        var parts = ["恢复 \(added) 条记录"]
        if conflicts > 0 { parts.append("另存 \(conflicts) 条冲突副本") }
        if repairedAudio > 0 { parts.append("补回 \(repairedAudio) 个录音") }
        if skipped > 0 { parts.append("跳过 \(skipped) 条重复记录") }
        if settingsRestored { parts.append("已恢复设置") }
        if missingAudio > 0 { parts.append("\(missingAudio) 条缺失录音的引用已保留") }
        return parts.joined(separator: "，") + "。"
    }
}

private struct BackupPreferences: Codable {
    var folderBookmark: Data?
    var folderName: String?
    var lastSuccess: Date?
    var lastAttempt: Date?
    var lastError: String?
}

@MainActor
final class BackupService: ObservableObject {
    private let store: DiaryStore
    private var preferences = BackupPreferences()
    private var isBackingUp = false
    @Published private(set) var statusText = "尚未备份。选择文件夹后，可在打开 App 时自动补备份。"
    @Published private(set) var selectedFolderName: String?
    @Published private(set) var lastSuccessfulBackupAt: Date?
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var lastError: String?

    init(store: DiaryStore) {
        self.store = store
        if FileManager.default.fileExists(atPath: AppPaths.backupPreferencesFile.path) {
            do {
                preferences = try BackupJSON.decoder().decode(BackupPreferences.self, from: Data(contentsOf: AppPaths.backupPreferencesFile))
            } catch { statusText = "无法读取上次的备份状态，请重新选择备份文件夹。" }
        }
        publishStatus()
    }

    /// Call with a folder returned by the system document picker, not a URL string.
    /// Bookmarks are kept locally and never exported in a diary backup.
    func chooseFolder(url: URL) throws {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DiaryError.folderUnavailable
        }
        let homePath = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
        guard !url.standardizedFileURL.path.hasPrefix(homePath) else {
            throw DiaryError.io("请选择 iCloud Drive 或其他应用的文件夹。应用自己的存储会随卸载删除，不能用作恢复备份。")
        }
        let probe = url.appendingPathComponent(".three-moments-write-\(UUID().uuidString)")
        try Data().write(to: probe, options: .atomic)
        try FileManager.default.removeItem(at: probe)
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let before = preferences
        preferences.folderBookmark = bookmark
        preferences.folderName = url.lastPathComponent
        preferences.lastError = nil
        do { try savePreferences() }
        catch { preferences = before; throw error }
        publishStatus()
    }

    func clearSelectedFolder() throws {
        let before = preferences
        preferences.folderBookmark = nil
        preferences.folderName = nil
        do { try savePreferences() }
        catch { preferences = before; throw error }
        publishStatus()
    }

    /// A foreground check, not a promise that iOS will wake the app every week.
    func backupIfDue() async {
        guard store.settings.automaticBackupEnabled, preferences.folderBookmark != nil, !isBackingUp else { return }
        let seconds = TimeInterval(store.settings.backupIntervalDays) * 24 * 60 * 60
        guard preferences.lastSuccess.map({ Date().timeIntervalSince($0) >= seconds }) ?? true else { return }
        // Avoid repeated provider requests while a failed destination remains offline.
        if preferences.lastError != nil,
           let attempt = preferences.lastAttempt, Date().timeIntervalSince(attempt) < 60 { return }
        do { _ = try backupNow() }
        catch { /* backupNow publishes the concrete failure for the settings screen. */ }
    }

    @discardableResult
    func backupNow() throws -> URL {
        guard !isBackingUp else { throw DiaryError.io("备份正在进行，请稍后再试。") }
        isBackingUp = true
        defer { isBackingUp = false }
        preferences.lastAttempt = Date()
        do {
            guard let bookmark = preferences.folderBookmark else { throw DiaryError.chooseBackupFolder }
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            let didStart = folder.startAccessingSecurityScopedResource()
            defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
            if stale {
                preferences.folderBookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            let snapshots = store.entries.map { store.snapshot(for: $0) }
            let fm = FileManager.default
            let tag = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = "三件事日记-\(tag)-\(UUID().uuidString.prefix(6))"
            let temporary = folder.appendingPathComponent(".\(name).partial", isDirectory: true)
            let destination = folder.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
            do {
                let audio = temporary.appendingPathComponent("audio", isDirectory: true)
                let days = temporary.appendingPathComponent("days", isDirectory: true)
                try fm.createDirectory(at: audio, withIntermediateDirectories: false)
                try fm.createDirectory(at: days, withIntermediateDirectories: false)
                var attachments: [String: String] = [:]
                var hashes: [String: String] = [:]
                for snapshot in snapshots {
                    if let name = snapshot.audioFilename {
                        let source = try AppPaths.audioURL(filename: name)
                        guard fm.fileExists(atPath: source.path) else { throw DiaryError.missingAudio(name) }
                        let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
                        let target = audio.appendingPathComponent(name)
                        if !fm.fileExists(atPath: target.path) { try bytes.write(to: target, options: .atomic) }
                        attachments[snapshot.id.uuidString] = "audio/\(name)"
                        hashes[name] = Self.digest(bytes)
                    }
                }
                let document = BackupDocument(entries: snapshots, settings: store.settings, exportedAt: Date(),
                                              backupKind: "folder", audioAttachments: attachments, audioSHA256: hashes)
                try BackupJSON.encoder().encode(document).write(to: temporary.appendingPathComponent("records.json"), options: .atomic)
                for day in Set(snapshots.map(\.date)).sorted() {
                    let body = Self.markdown(entries: snapshots.filter { $0.date == day }, audioPrefix: "../audio/")
                    try Data(body.utf8).write(to: days.appendingPathComponent("\(day).md"), options: .atomic)
                }
                let readme = "三件事日记备份\n\nrecords.json 是完整记录与设置。days/ 为逐日日记。audio/ 为录音附件。\n恢复时请选择整个备份文件夹。请保留原始文件名与相对目录。\n备份内容未加密，请将文件夹保存在你信任的位置。\n"
                try Data(readme.utf8).write(to: temporary.appendingPathComponent("说明.txt"), options: .atomic)
                // Validate the complete folder before making it visible as a finished backup.
                _ = try readImport(at: temporary)
                try fm.moveItem(at: temporary, to: destination)
            } catch {
                try? fm.removeItem(at: temporary)
                throw error
            }
            preferences.lastSuccess = Date()
            preferences.lastError = nil
            try savePreferences()
            publishStatus()
            return destination
        } catch {
            preferences.lastError = error.localizedDescription
            try? savePreferences()
            publishStatus()
            throw error
        }
    }

    /// A shareable record-only JSON, useful before a backup folder has been chosen.
    /// Audio references stay in the JSON; the preview explains missing attachments.
    func exportRecordsJSON() throws -> URL {
        try AppPaths.ensureDirectories()
        let document = BackupDocument(entries: store.entries.map { store.snapshot(for: $0) }, settings: store.settings,
                                      exportedAt: Date(), backupKind: "records-only", audioAttachments: nil, audioSHA256: nil)
        let url = AppPaths.exportsDirectory.appendingPathComponent("三件事日记-\(DateKey.today)-\(UUID().uuidString.prefix(6)).json")
        try BackupJSON.encoder().encode(document).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    func exportMarkdown() throws -> URL {
        try AppPaths.ensureDirectories()
        let url = AppPaths.exportsDirectory.appendingPathComponent("三件事日记-\(DateKey.today)-\(UUID().uuidString.prefix(6)).md")
        let body = Self.markdown(entries: store.entries.map { store.snapshot(for: $0) }, audioPrefix: nil)
        try Data(body.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    /// Reads every attachment while the picker access is active. Confirmation can
    /// happen later without depending on a security-scoped URL remaining open.
    func prepareImport(from url: URL) throws -> ImportPreview {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try readImport(at: url)
    }

    func restore(from url: URL) throws -> ImportReport { try restore(prepareImport(from: url)) }

    func restore(_ preview: ImportPreview) throws -> ImportReport {
        try preview.document.validate()
        var report = ImportReport()
        var planned: [EntrySnapshot] = []
        var repaired: [EntrySnapshot] = []
        var copies: [String: Data] = [:]
        var known = store.entries.map { store.snapshot(for: $0) }
        let sourceFingerprint = "sha256:" + Self.digest(try BackupJSON.encoder().encode(preview.document))

        for incoming in preview.document.entries {
            let family = incoming.conflictOf ?? incoming.id
            let candidate = known.first { existing in
                let related = existing.id == incoming.id || existing.conflictOf == family || existing.id == family
                guard related, existing.sameContent(as: incoming, ignoreAudioFilename: true) else { return false }
                return audioEquivalent(existing: existing, incoming: incoming, imported: preview.audioData)
            }
            if let candidate {
                if candidate.audioFilename == nil,
                   let sourceName = incoming.audioFilename ?? incoming.missingAudioRef,
                   let bytes = preview.audioData[sourceName] {
                    var updated = candidate
                    let name = uniqueAudioName(original: sourceName, reserved: Set(copies.keys))
                    updated.audioFilename = name
                    updated.missingAudioRef = nil
                    updated.originalAudioRef = incoming.originalAudioRef ?? sourceName
                    copies[name] = bytes
                    repaired.append(updated)
                    if let index = known.firstIndex(where: { $0.id == updated.id }) { known[index] = updated }
                    report.repairedAudio += 1
                } else { report.skipped += 1 }
                continue
            }
            var value = incoming
            if known.contains(where: { $0.id == incoming.id }) {
                value.id = UUID()
                value.conflictOf = family
                value.restoredAt = Date()
                value.conflictSource = sourceFingerprint
                report.conflicts += 1
            } else { report.added += 1 }
            if let sourceName = incoming.audioFilename ?? incoming.missingAudioRef {
                if let bytes = preview.audioData[sourceName] {
                    let name = uniqueAudioName(original: sourceName, reserved: Set(copies.keys))
                    value.audioFilename = name
                    value.missingAudioRef = nil
                    value.originalAudioRef = incoming.originalAudioRef ?? sourceName
                    copies[name] = bytes
                } else {
                    value.audioFilename = nil
                    value.missingAudioRef = sourceName
                    value.originalAudioRef = incoming.originalAudioRef ?? sourceName
                    report.missingAudio += 1
                }
            }
            planned.append(value)
            known.append(value)
        }

        // Validate all inputs before creating files or changing SwiftData.
        for value in planned + repaired { try value.validate() }
        try AppPaths.ensureDirectories()
        let fm = FileManager.default
        var copied: [URL] = []
        do {
            for (name, bytes) in copies {
                let url = try AppPaths.audioURL(filename: name)
                guard !fm.fileExists(atPath: url.path) else { throw DiaryError.io("录音文件编号冲突，请重新导入。") }
                try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                copied.append(url)
            }
            try store.insertImported(planned, settings: preview.document.settings, updating: repaired)
        } catch {
            var cleanupErrors: [String] = []
            for url in copied {
                do { try fm.removeItem(at: url) } catch { cleanupErrors.append(error.localizedDescription) }
            }
            if !cleanupErrors.isEmpty { throw DiaryError.rollbackFailed(cleanupErrors.joined(separator: "; ")) }
            throw error
        }
        report.settingsRestored = preview.document.settings != nil
        return report
    }

    private func readImport(at source: URL) throws -> ImportPreview {
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &directory) else { throw DiaryError.invalidBackup("文件无法访问。") }
        let recordsURL = directory.boolValue ? source.appendingPathComponent("records.json") : source
        if directory.boolValue {
            let root = source.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard recordsURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else {
                throw DiaryError.invalidBackup("记录文件路径超出备份文件夹。")
            }
        }
        let document = try BackupJSON.decoder().decode(BackupDocument.self, from: Data(contentsOf: recordsURL))
        try document.validate()
        var attachments: [String: Data] = [:]
        var missing = 0
        for item in document.entries {
            guard let filename = item.audioFilename ?? item.missingAudioRef else { continue }
            if directory.boolValue {
                let expectedPath = "audio/\(filename)"
                if let declared = document.audioAttachments?[item.id.uuidString], declared != expectedPath {
                    throw DiaryError.invalidBackup("录音附件的相对路径无效。")
                }
                let audioURL = source.appendingPathComponent("audio", isDirectory: true).appendingPathComponent(filename)
                // Disallow symlinks escaping the selected backup folder.
                let resolvedRoot = source.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard audioURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot) else {
                    throw DiaryError.invalidBackup("附件路径超出备份文件夹。")
                }
                guard fm.fileExists(atPath: audioURL.path) else {
                    if item.audioFilename != nil { throw DiaryError.missingAudio(filename) }
                    // A record-only restore can intentionally carry a missing ref.
                    // It is not advertised as a playable or bundled attachment.
                    missing += 1
                    continue
                }
                let bytes = try Data(contentsOf: audioURL)
                if let hash = document.audioSHA256?[filename], hash != Self.digest(bytes) {
                    throw DiaryError.invalidBackup("录音附件校验失败：\(filename)。")
                }
                attachments[filename] = bytes
            } else { missing += 1 }
        }
        return ImportPreview(document: document, sourceName: source.lastPathComponent,
                             missingAudioCount: missing, audioData: attachments)
    }

    private func audioEquivalent(existing: EntrySnapshot, incoming: EntrySnapshot, imported: [String: Data]) -> Bool {
        let lhs = existing.originalAudioRef ?? existing.audioFilename ?? existing.missingAudioRef
        let rhs = incoming.originalAudioRef ?? incoming.audioFilename ?? incoming.missingAudioRef
        guard (lhs == nil) == (rhs == nil) else { return false }
        guard let lhs, let rhs else { return true }
        if let existingFile = existing.audioFilename,
           let url = try? AppPaths.audioURL(filename: existingFile),
           let local = try? Data(contentsOf: url, options: .mappedIfSafe),
           let incomingName = incoming.audioFilename ?? incoming.missingAudioRef,
           let remote = imported[incomingName] {
            return Self.digest(local) == Self.digest(remote)
        }
        // Renamed local files from a previous import retain content/transcript/date.
        // Missing references only match the same original filename.
        return lhs == rhs
    }

    private func uniqueAudioName(original: String, reserved: Set<String>) -> String {
        let fm = FileManager.default
        if !reserved.contains(original), !fm.fileExists(atPath: AppPaths.audioDirectory.appendingPathComponent(original).path) { return original }
        let ext = (original as NSString).pathExtension
        var name: String
        repeat {
            name = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        } while reserved.contains(name) || fm.fileExists(atPath: AppPaths.audioDirectory.appendingPathComponent(name).path)
        return name
    }

    private func savePreferences() throws {
        try BackupJSON.encoder().encode(preferences).write(to: AppPaths.backupPreferencesFile,
                                                         options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func publishStatus() {
        selectedFolderName = preferences.folderName
        lastSuccessfulBackupAt = preferences.lastSuccess
        lastAttemptAt = preferences.lastAttempt
        lastError = preferences.lastError
        if let error = preferences.lastError { statusText = "上次备份未成功：\(error) 下次打开 App 时会再次尝试，也可以手动重试。" }
        else if let success = preferences.lastSuccess {
            let relative = RelativeDateTimeFormatter().localizedString(for: success, relativeTo: Date())
            statusText = "最近成功备份：\(relative)。App 打开时会检查是否需要补备份。"
        } else if preferences.folderBookmark != nil { statusText = "已选择备份文件夹，下次打开 App 时会创建首次备份。" }
        else { statusText = "尚未备份。请选择应用外的文件夹，避免卸载时丢失恢复副本。" }
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func markdown(entries: [EntrySnapshot], audioPrefix: String?) -> String {
        let names = ["thought": "想法", "quote": "说过的话", "detail": "细节", "unsorted": "未分类"]
        var output = "# 三件事日记\n\n"
        let grouped = Dictionary(grouping: entries, by: \.date)
        for day in grouped.keys.sorted() {
            output += "## \(day)\n\n"
            for entry in (grouped[day] ?? []).sorted(by: { $0.createdAt < $1.createdAt }) {
                output += "### \(names[entry.type] ?? entry.type)\n\n\(entry.content)\n\n"
                if let speaker = entry.speaker, !speaker.isEmpty { output += "说话人：\(speaker)（\(entry.certainty == "verbatim" ? "原话" : "大意")）\n\n" }
                if let basis = entry.basis, !basis.isEmpty { output += "依据：\(basis)\n\n" }
                if let prediction = entry.prediction, !prediction.isEmpty { output += "判断：\(prediction)\n\n" }
                if let confidence = entry.confidence { output += "把握程度：\(confidence)%\n\n" }
                if let reaction = entry.myReaction, !reaction.isEmpty { output += "当时的反应：\(reaction)\n\n" }
                if let transcript = entry.transcriptRaw { output += "转写原文：\n\n\(transcript)\n\n" }
                if let audio = entry.audioFilename {
                    if let prefix = audioPrefix {
                        let path = (prefix + audio).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? (prefix + audio)
                        output += "[原始录音](\(path))\n\n"
                    } else { output += "录音附件：\(audio)（仅完整文件夹备份包含音频）\n\n" }
                }
                if let missing = entry.missingAudioRef { output += "缺失录音引用：\(missing)\n\n" }
                if entry.isBackfilled { output += "补记\n\n" }
                if entry.hideFromResurface { output += "不主动展示\n\n" }
                if let original = entry.conflictOf { output += "恢复冲突副本，原编号：\(original.uuidString)\n\n" }
                // JSON metadata preserves newlines and all original field values even
                // when the user's text itself contains Markdown punctuation/fences.
                if let data = try? BackupJSON.encoder().encode(entry), let json = String(data: data, encoding: .utf8) {
                    let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: json) + 1))
                    output += "\(fence)json\n\(json)\n\(fence)\n\n"
                }
            }
        }
        return output
    }

    private static func longestBacktickRun(in string: String) -> Int {
        var longest = 0, current = 0
        for character in string {
            if character == "`" { current += 1; longest = max(longest, current) }
            else { current = 0 }
        }
        return longest
    }
}
