import Foundation
import SwiftData

/// The editable content and its original voice transcript have separate fields.
/// Editors must leave transcriptRaw unchanged after a recording is first saved.
@Model
final class DiaryEntry {
    @Attribute(.unique) var id: UUID
    var date: String
    var createdAt: Date
    var updatedAt: Date
    var type: String
    var inputMethod: String
    var content: String
    var transcriptRaw: String?
    var audioFilename: String?
    var missingAudioRef: String?
    var originalAudioRef: String?
    var basis: String?
    var prediction: String?
    var confidence: Int?
    var speaker: String?
    var certainty: String?
    var myReaction: String?
    var isBackfilled: Bool
    var hideFromResurface: Bool
    var captureOrigin: Bool
    var conflictOf: UUID?
    var restoredAt: Date?
    var conflictSource: String?

    init(snapshot: EntrySnapshot) {
        id = snapshot.id
        date = snapshot.date
        createdAt = snapshot.createdAt
        updatedAt = snapshot.updatedAt
        type = snapshot.type
        inputMethod = snapshot.inputMethod
        content = snapshot.content
        transcriptRaw = snapshot.transcriptRaw
        audioFilename = snapshot.audioFilename
        missingAudioRef = snapshot.missingAudioRef
        originalAudioRef = snapshot.originalAudioRef
        basis = snapshot.basis
        prediction = snapshot.prediction
        confidence = snapshot.confidence
        speaker = snapshot.speaker
        certainty = snapshot.certainty
        myReaction = snapshot.myReaction
        isBackfilled = snapshot.isBackfilled
        hideFromResurface = snapshot.hideFromResurface
        captureOrigin = snapshot.captureOrigin
        conflictOf = snapshot.conflictOf
        restoredAt = snapshot.restoredAt
        conflictSource = snapshot.conflictSource
    }

    func apply(_ value: EntrySnapshot) {
        date = value.date
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        type = value.type
        inputMethod = value.inputMethod
        content = value.content
        transcriptRaw = value.transcriptRaw
        audioFilename = value.audioFilename
        missingAudioRef = value.missingAudioRef
        originalAudioRef = value.originalAudioRef
        basis = value.basis
        prediction = value.prediction
        confidence = value.confidence
        speaker = value.speaker
        certainty = value.certainty
        myReaction = value.myReaction
        isBackfilled = value.isBackfilled
        hideFromResurface = value.hideFromResurface
        captureOrigin = value.captureOrigin
        conflictOf = value.conflictOf
        restoredAt = value.restoredAt
        conflictSource = value.conflictSource
    }
}

enum DateKey {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static var today: String { string(from: Date()) }

    static func date(from string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: string), self.string(from: date) == string else { return nil }
        return date
    }
}

struct EntrySnapshot: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var date: String = DateKey.today
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var type: String = "unsorted"
    var inputMethod: String = "text"
    var content: String = ""
    var transcriptRaw: String? = nil
    var audioFilename: String? = nil
    var missingAudioRef: String? = nil
    var originalAudioRef: String? = nil
    var basis: String? = nil
    var prediction: String? = nil
    var confidence: Int? = nil
    var speaker: String? = nil
    var certainty: String? = nil
    var myReaction: String? = nil
    var isBackfilled: Bool = false
    var hideFromResurface: Bool = false
    var captureOrigin: Bool = false
    var conflictOf: UUID? = nil
    var restoredAt: Date? = nil
    var conflictSource: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, date, type, content, basis, prediction, confidence, speaker, certainty
        case createdAt = "created_at", updatedAt = "updated_at"
        case inputMethod = "input_method", transcriptRaw = "transcript_raw"
        case audioFilename = "audio_ref", oldAudioFilename = "audio_filename"
        case missingAudioRef = "missing_audio_ref", originalAudioRef = "original_audio_ref", myReaction = "my_reaction"
        case isBackfilled = "is_backfilled", hideFromResurface = "hide_from_resurface"
        case captureOrigin = "capture_origin", conflictOf = "conflict_of"
        case restoredAt = "restored_at", conflictSource = "conflict_source"
    }

    init(id: UUID = UUID(), date: String = DateKey.today, createdAt: Date = Date(),
         updatedAt: Date = Date(), type: String = "unsorted", inputMethod: String = "text",
         content: String = "", transcriptRaw: String? = nil, audioFilename: String? = nil, missingAudioRef: String? = nil, originalAudioRef: String? = nil,
         basis: String? = nil, prediction: String? = nil, confidence: Int? = nil,
         speaker: String? = nil, certainty: String? = nil, myReaction: String? = nil,
         isBackfilled: Bool = false, hideFromResurface: Bool = false,
         captureOrigin: Bool = false, conflictOf: UUID? = nil,
         restoredAt: Date? = nil, conflictSource: String? = nil) {
        self.id = id; self.date = date; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.type = type; self.inputMethod = inputMethod; self.content = content
        self.transcriptRaw = transcriptRaw; self.audioFilename = audioFilename; self.missingAudioRef = missingAudioRef
        self.originalAudioRef = originalAudioRef
        self.basis = basis; self.prediction = prediction; self.confidence = confidence
        self.speaker = speaker; self.certainty = certainty; self.myReaction = myReaction
        self.isBackfilled = isBackfilled; self.hideFromResurface = hideFromResurface
        self.captureOrigin = captureOrigin; self.conflictOf = conflictOf
        self.restoredAt = restoredAt; self.conflictSource = conflictSource
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        type = try c.decode(String.self, forKey: .type)
        content = try c.decode(String.self, forKey: .content)
        inputMethod = try c.decodeIfPresent(String.self, forKey: .inputMethod) ?? "text"
        transcriptRaw = try c.decodeIfPresent(String.self, forKey: .transcriptRaw)
        audioFilename = try c.decodeIfPresent(String.self, forKey: .audioFilename)
            ?? c.decodeIfPresent(String.self, forKey: .oldAudioFilename)
        if let reference = audioFilename, reference.hasPrefix("audio/") {
            audioFilename = String(reference.dropFirst("audio/".count))
        }
        missingAudioRef = try c.decodeIfPresent(String.self, forKey: .missingAudioRef)
        originalAudioRef = try c.decodeIfPresent(String.self, forKey: .originalAudioRef)
        basis = try c.decodeIfPresent(String.self, forKey: .basis)
        prediction = try c.decodeIfPresent(String.self, forKey: .prediction)
        // Earlier web exports may store a number as a string.
        if c.contains(.confidence), !(try c.decodeNil(forKey: .confidence)) {
            do { confidence = try c.decode(Int.self, forKey: .confidence) }
            catch {
                let text = try c.decode(String.self, forKey: .confidence)
                confidence = text.isEmpty ? nil : Int(text)
                if !text.isEmpty && confidence == nil {
                    throw DiaryError.invalidBackup("把握程度必须是 0 到 100 的整数。")
                }
            }
        } else { confidence = nil }
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        certainty = try c.decodeIfPresent(String.self, forKey: .certainty)
        myReaction = try c.decodeIfPresent(String.self, forKey: .myReaction)
        isBackfilled = try c.decodeIfPresent(Bool.self, forKey: .isBackfilled) ?? false
        hideFromResurface = try c.decodeIfPresent(Bool.self, forKey: .hideFromResurface) ?? false
        captureOrigin = try c.decodeIfPresent(Bool.self, forKey: .captureOrigin) ?? (type == "unsorted")
        conflictOf = try c.decodeIfPresent(UUID.self, forKey: .conflictOf)
        restoredAt = try c.decodeIfPresent(Date.self, forKey: .restoredAt)
        conflictSource = try c.decodeIfPresent(String.self, forKey: .conflictSource)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(date, forKey: .date)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(type, forKey: .type); try c.encode(content, forKey: .content)
        try c.encode(inputMethod, forKey: .inputMethod)
        try c.encodeIfPresent(transcriptRaw, forKey: .transcriptRaw)
        try c.encodeIfPresent(audioFilename, forKey: .audioFilename)
        try c.encodeIfPresent(missingAudioRef, forKey: .missingAudioRef)
        try c.encodeIfPresent(originalAudioRef, forKey: .originalAudioRef)
        try c.encodeIfPresent(basis, forKey: .basis); try c.encodeIfPresent(prediction, forKey: .prediction)
        try c.encodeIfPresent(confidence, forKey: .confidence); try c.encodeIfPresent(speaker, forKey: .speaker)
        try c.encodeIfPresent(certainty, forKey: .certainty); try c.encodeIfPresent(myReaction, forKey: .myReaction)
        try c.encode(isBackfilled, forKey: .isBackfilled); try c.encode(hideFromResurface, forKey: .hideFromResurface)
        try c.encode(captureOrigin, forKey: .captureOrigin); try c.encodeIfPresent(conflictOf, forKey: .conflictOf)
        try c.encodeIfPresent(restoredAt, forKey: .restoredAt); try c.encodeIfPresent(conflictSource, forKey: .conflictSource)
    }

    func validate() throws {
        guard DateKey.date(from: date) != nil else { throw DiaryError.invalidBackup("记录日期无效。") }
        guard createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              restoredAt?.timeIntervalSince1970.isFinite ?? true else { throw DiaryError.invalidBackup("记录时间无效。") }
        guard ["thought", "quote", "detail", "unsorted"].contains(type) else {
            throw DiaryError.invalidBackup("记录分类无法识别。")
        }
        guard ["text", "voice"].contains(inputMethod) else {
            throw DiaryError.invalidBackup("记录的输入方式无法识别。")
        }
        let hasText = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasVoice = inputMethod == "voice" && (audioFilename != nil || missingAudioRef != nil
            || !(transcriptRaw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard hasText || hasVoice else { throw DiaryError.invalidBackup("记录没有文字、录音或转写内容。") }
        if let confidence, !(0...100).contains(confidence) {
            throw DiaryError.invalidBackup("把握程度必须在 0 到 100 之间。")
        }
        if let certainty, !certainty.isEmpty, !["gist", "verbatim"].contains(certainty) {
            throw DiaryError.invalidBackup("原话准确程度必须是 gist 或 verbatim。")
        }
        if let audioFilename, !AppPaths.isSafeFilename(audioFilename) {
            throw DiaryError.invalidBackup("录音附件的文件名无效。")
        }
        if let missingAudioRef, !AppPaths.isSafeFilename(missingAudioRef) {
            throw DiaryError.invalidBackup("缺失录音的引用无效。")
        }
        if let originalAudioRef, !AppPaths.isSafeFilename(originalAudioRef) {
            throw DiaryError.invalidBackup("录音的原始引用无效。")
        }
    }

    /// ID and restore bookkeeping do not define an entry's semantic content.
    /// Timestamps and the original transcript remain significant.
    func sameContent(as other: EntrySnapshot, ignoreAudioFilename: Bool = false) -> Bool {
        var a = self, b = other
        // ISO exports preserve milliseconds. A native Date may carry finer precision,
        // so compare timestamps at the format's precision without erasing their meaning.
        guard BackupJSON.timestamp(a.createdAt) == BackupJSON.timestamp(b.createdAt),
              BackupJSON.timestamp(a.updatedAt) == BackupJSON.timestamp(b.updatedAt) else { return false }
        a.createdAt = b.createdAt; a.updatedAt = b.updatedAt
        let neutral = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        a.id = neutral; b.id = neutral
        a.conflictOf = nil; b.conflictOf = nil
        a.restoredAt = nil; b.restoredAt = nil
        a.conflictSource = nil; b.conflictSource = nil
        a.audioFilename = a.audioFilename ?? a.missingAudioRef
        b.audioFilename = b.audioFilename ?? b.missingAudioRef
        a.missingAudioRef = nil; b.missingAudioRef = nil
        a.originalAudioRef = nil; b.originalAudioRef = nil
        a.basis = a.basis?.isEmpty == true ? nil : a.basis
        b.basis = b.basis?.isEmpty == true ? nil : b.basis
        a.prediction = a.prediction?.isEmpty == true ? nil : a.prediction
        b.prediction = b.prediction?.isEmpty == true ? nil : b.prediction
        a.speaker = a.speaker?.isEmpty == true ? nil : a.speaker
        b.speaker = b.speaker?.isEmpty == true ? nil : b.speaker
        a.certainty = a.certainty?.isEmpty == true ? nil : a.certainty
        b.certainty = b.certainty?.isEmpty == true ? nil : b.certainty
        a.myReaction = a.myReaction?.isEmpty == true ? nil : a.myReaction
        b.myReaction = b.myReaction?.isEmpty == true ? nil : b.myReaction
        if ignoreAudioFilename { a.audioFilename = nil; b.audioFilename = nil }
        return a == b
    }
}

enum DiaryError: LocalizedError {
    case invalidBackup(String)
    case missingEntry
    case chooseBackupFolder
    case folderUnavailable
    case missingAudio(String)
    case io(String)
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBackup(let detail): return "无法恢复备份：\(detail)"
        case .missingEntry: return "这条记录已不存在，请刷新后重试。"
        case .chooseBackupFolder: return "先选择备份文件夹，再创建完整备份。"
        case .folderUnavailable: return "无法访问备份文件夹，请重新选择。"
        case .missingAudio(let name): return "缺少录音附件：\(name)。请选择包含 audio 文件夹的完整备份。"
        case .io(let detail): return detail
        case .rollbackFailed(let detail): return "操作未完成，恢复原状时也遇到了问题。请保留应用数据并重试：\(detail)"
        }
    }
}
