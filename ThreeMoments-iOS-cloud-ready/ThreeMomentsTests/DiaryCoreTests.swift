import XCTest
@testable import ThreeMoments

final class DiaryCoreTests: XCTestCase {
    @MainActor
    private func withStore(_ body: (DiaryStore, URL) throws -> Void) throws {
        #if DEBUG
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiaryCoreTests-\(UUID().uuidString)", isDirectory: true)
        let previous = AppPaths.testingRoot
        AppPaths.testingRoot = folder
        defer {
            AppPaths.testingRoot = previous
            try? FileManager.default.removeItem(at: folder)
        }
        let store = try DiaryStore(inMemory: true)
        try body(store, folder)
        #else
        throw XCTSkip("Core storage tests require the isolated Debug storage hook.")
        #endif
    }

    private func fixture(id: UUID = UUID()) -> [String: Any] {
        ["id": id.uuidString.lowercased(), "date": "2026-10-20",
         "created_at": "2026-10-20T10:15:00.123Z", "updated_at": "2026-10-20T10:15:00Z",
         "type": "unsorted", "content": "原文第一行\n原文第二行。", "input_method": "voice",
         "transcript_raw": "原始 转写。", "audio_ref": "voice.m4a"]
    }

    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    @MainActor
    func testLegacyJSONPreservesTextAndExportsCanonicalAudioReference() throws {
        let record = fixture()
        let document = try BackupJSON.decoder().decode(BackupDocument.self, from: data([
            "format": "three-moments", "version": 1, "entries": [record],
            "settings": ["remind": true, "time": "21:30"]
        ]))
        try document.validate()
        XCTAssertEqual(document.entries[0].content, "原文第一行\n原文第二行。")
        XCTAssertEqual(document.entries[0].transcriptRaw, "原始 转写。")
        XCTAssertTrue(document.entries[0].captureOrigin)
        XCTAssertEqual(document.settings?.reminderTime, "21:30")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: BackupJSON.encoder().encode(document.entries[0])) as? [String: Any])
        XCTAssertEqual(object["audio_ref"] as? String, "voice.m4a")
        XCTAssertNil(object["audio_filename"])
        XCTAssertNotNil(object["created_at"])
    }

    @MainActor
    func testDecoderRejectsUnsafeOrInvalidRecordBeforeImport() throws {
        for invalid in [
            ["confidence": 50.5], ["confidence": 101], ["confidence": "不确定"],
            ["certainty": "invented"], ["date": "2026-02-30"], ["audio_ref": "../private.m4a"],
            ["created_at": "not-a-date"], ["type": "badge"]
        ] as [[String: Any]] {
            var record = fixture()
            record.merge(invalid) { _, new in new }
            XCTAssertThrowsError(try BackupJSON.decoder().decode(EntrySnapshot.self, from: data(record)), "Accepted invalid fields: \(invalid.keys)")
        }
        var legacy = fixture()
        legacy.removeValue(forKey: "audio_ref")
        legacy["audio_filename"] = "old.m4a"
        XCTAssertEqual(try BackupJSON.decoder().decode(EntrySnapshot.self, from: data(legacy)).audioFilename, "old.m4a")
        XCTAssertThrowsError(try EntrySnapshot(content: " \n").validate())
        XCTAssertNoThrow(try EntrySnapshot(inputMethod: "voice", audioFilename: "voice.m4a").validate())
        XCTAssertNoThrow(try EntrySnapshot(inputMethod: "voice", transcriptRaw: "转写原文。").validate())
    }

    @MainActor
    func testCorrectionNeverChangesOriginalTranscriptAndUpdatesTimestamp() throws {
        try withStore { store, _ in
            let originalTime = Date(timeIntervalSince1970: 1_700_000_000)
            let entry = try store.add(snapshot: EntrySnapshot(createdAt: originalTime, updatedAt: originalTime,
                inputMethod: "voice", content: "校对前", transcriptRaw: "未校对 原文"))
            var edit = store.snapshot(for: entry)
            edit.content = "校对后\n保留段落"
            try store.update(entry: entry, using: edit)
            XCTAssertEqual(entry.transcriptRaw, "未校对 原文")
            XCTAssertGreaterThan(entry.updatedAt, originalTime)
            edit.transcriptRaw = "试图替换原文"
            XCTAssertThrowsError(try store.update(entry: entry, using: edit))
            try store.reload()
            XCTAssertEqual(store.entries.first?.content, "校对后\n保留段落")
            XCTAssertEqual(store.entries.first?.transcriptRaw, "未校对 原文")
        }
    }

    @MainActor
    func testRestoreKeepsOriginalAndDeduplicatesRepeatedConflict() throws {
        try withStore { store, folder in
            let original = EntrySnapshot(content: "原记录\n不能被改写。")
            _ = try store.add(snapshot: original)
            var incoming = original
            incoming.content = "备份中的另一版本。"
            let document = BackupDocument(entries: [incoming], settings: nil, exportedAt: Date(), backupKind: "records-only")
            let source = folder.appendingPathComponent("incoming.json")
            try BackupJSON.encoder().encode(document).write(to: source)
            let backup = BackupService(store: store)
            let preview = try backup.prepareImport(from: source)
            let first = try backup.restore(preview)
            XCTAssertEqual(first.conflicts, 1)
            XCTAssertEqual(first.added, 0)
            XCTAssertEqual(store.entries.count, 2)
            let preserved = try XCTUnwrap(store.entries.first(where: { $0.id == original.id }))
            XCTAssertEqual(preserved.content, original.content)
            let conflict = try XCTUnwrap(store.entries.first(where: { $0.conflictOf == original.id }))
            XCTAssertEqual(conflict.content, incoming.content)
            XCTAssertNotNil(conflict.restoredAt)
            XCTAssertTrue(conflict.conflictSource?.hasPrefix("sha256:") == true)
            let second = try backup.restore(preview)
            XCTAssertEqual(second.skipped, 1)
            XCTAssertEqual(second.conflicts, 0)
            XCTAssertEqual(store.entries.count, 2)
        }
    }

    @MainActor
    func testNativeExportReimportDoesNotCreateFalseTimestampConflict() throws {
        try withStore { store, _ in
            let time = Date(timeIntervalSince1970: 1_792_488_900.123456)
            _ = try store.add(snapshot: EntrySnapshot(createdAt: time, updatedAt: time,
                type: "thought", content: "时间精度不能制造冲突。"))
            let service = BackupService(store: store)
            let exported = try service.exportRecordsJSON()
            let result = try service.restore(service.prepareImport(from: exported))
            XCTAssertEqual(result.skipped, 1)
            XCTAssertEqual(result.conflicts, 0)
            XCTAssertEqual(store.entries.count, 1)
        }
    }

    @MainActor
    func testIncompleteFolderFailsBeforeAnyMutationAndFullFolderRepairsJSONAudio() throws {
        try withStore { store, folder in
            let imported = EntrySnapshot(inputMethod: "voice", content: "校对后的正文。", transcriptRaw: "原始 转写。", audioFilename: "sample.m4a")
            let document = BackupDocument(entries: [imported], settings: nil, exportedAt: Date(), backupKind: "folder")
            let source = folder.appendingPathComponent("Incoming", isDirectory: true)
            let audio = source.appendingPathComponent("audio", isDirectory: true)
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
            let records = source.appendingPathComponent("records.json")
            try BackupJSON.encoder().encode(document).write(to: records)
            let service = BackupService(store: store)
            XCTAssertThrowsError(try service.prepareImport(from: source))
            XCTAssertTrue(store.entries.isEmpty)
            // Selecting only records.json explicitly restores text, with disclosure.
            let textPreview = try service.prepareImport(from: records)
            XCTAssertEqual(textPreview.missingAudioCount, 1)
            let textReport = try service.restore(textPreview)
            XCTAssertEqual(textReport.added, 1)
            XCTAssertNil(store.entries.first?.audioFilename)
            XCTAssertEqual(store.entries.first?.missingAudioRef, "sample.m4a")
            XCTAssertEqual(store.entries.first?.transcriptRaw, "原始 转写。")
            let bytes = Data([1, 2, 3, 4, 5])
            try bytes.write(to: audio.appendingPathComponent("sample.m4a"))
            let repaired = try service.restore(service.prepareImport(from: source))
            XCTAssertEqual(repaired.repairedAudio, 1)
            XCTAssertEqual(store.entries.count, 1)
            XCTAssertNil(store.entries.first?.missingAudioRef)
            let filename = try XCTUnwrap(store.entries.first?.audioFilename)
            XCTAssertEqual(try Data(contentsOf: AppPaths.audioURL(filename: filename)), bytes)
            let repeated = try service.restore(service.prepareImport(from: source))
            XCTAssertEqual(repeated.skipped, 1)
            XCTAssertEqual(store.entries.count, 1)
        }
    }

    @MainActor
    func testDeleteAllIncludesDraftOrphanAudioAndShareCopies() throws {
        try withStore { store, _ in
            try store.saveDraft("未保存的草稿。")
            try Data([10, 20]).write(to: AppPaths.audioURL(filename: "owned.m4a"))
            try Data([30]).write(to: AppPaths.audioURL(filename: "orphan.m4a"))
            _ = try store.add(snapshot: EntrySnapshot(inputMethod: "voice", content: "记录。", transcriptRaw: "原文。", audioFilename: "owned.m4a"))
            let service = BackupService(store: store)
            let share = try service.exportRecordsJSON()
            XCTAssertTrue(FileManager.default.fileExists(atPath: share.path))
            try store.deleteAll()
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertEqual(store.loadDraft(), "")
            XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.draftFile.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: AppPaths.audioDirectory.path).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: share.path))
        }
    }

    @MainActor
    func testDifferentAudioReferenceWithoutBytesCreatesConflict() throws {
        try withStore { store, folder in
            try Data([1, 2, 3]).write(to: AppPaths.audioURL(filename: "A.m4a"))
            let original = EntrySnapshot(inputMethod: "voice", content: "同一句话。", audioFilename: "A.m4a")
            _ = try store.add(snapshot: original)
            var incoming = original
            incoming.audioFilename = "B.m4a"
            let document = BackupDocument(entries: [incoming], settings: nil, exportedAt: Date(), backupKind: "records-only")
            let source = folder.appendingPathComponent("different-reference.json")
            try BackupJSON.encoder().encode(document).write(to: source)
            let service = BackupService(store: store)
            let result = try service.restore(service.prepareImport(from: source))
            XCTAssertEqual(result.conflicts, 1)
            XCTAssertEqual(store.entries.count, 2)
            XCTAssertEqual(store.entries.first(where: { $0.id == original.id })?.audioFilename, "A.m4a")
            XCTAssertEqual(store.entries.first(where: { $0.conflictOf == original.id })?.missingAudioRef, "B.m4a")
            let again = try service.restore(service.prepareImport(from: source))
            XCTAssertEqual(again.skipped, 1)
            XCTAssertEqual(store.entries.count, 2)
        }
    }
    @MainActor
    func testPreparedDeletionJournalRestoresRowsAndAttachmentsAtStartup() throws {
        try withStore { store, _ in
            let original = EntrySnapshot(inputMethod: "voice", content: "原文不能丢。", audioFilename: "interrupted.m4a")
            let entry = try store.add(snapshot: original)
            let audio = try AppPaths.audioURL(filename: "interrupted.m4a")
            let bytes = Data([1, 9, 7, 3])
            try bytes.write(to: audio)
            let folder = AppPaths.recoveryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let staged = UUID().uuidString
            let encoded = try JSONSerialization.jsonObject(with: BackupJSON.encoder().encode([original]))
            let journal: [String: Any] = ["phase": "prepared", "before": encoded,
                "moves": [["location": "root", "name": "Audio/interrupted.m4a", "staged": staged]]]
            try JSONSerialization.data(withJSONObject: journal).write(to: folder.appendingPathComponent("journal.json"))
            try FileManager.default.moveItem(at: audio, to: folder.appendingPathComponent(staged))
            store.context.delete(entry)
            try store.context.save() // Simulate termination after save but before its durable commit marker.
            let reopened = try DiaryStore(inMemory: true)
            XCTAssertEqual(reopened.entries.count, 1)
            XCTAssertEqual(reopened.entries.first?.content, original.content)
            XCTAssertEqual(try Data(contentsOf: audio), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    @MainActor
    func testCommittedDeletionJournalOnlyFinishesRemovingStagedCopies() throws {
        try withStore { _, _ in
            let folder = AppPaths.recoveryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let staged = UUID().uuidString
            try Data([4, 5, 6]).write(to: folder.appendingPathComponent(staged))
            let journal: [String: Any] = ["phase": "committed", "before": [],
                "moves": [["location": "root", "name": "Audio/deleted.m4a", "staged": staged]]]
            try JSONSerialization.data(withJSONObject: journal).write(to: folder.appendingPathComponent("journal.json"))
            let reopened = try DiaryStore(inMemory: true)
            XCTAssertTrue(reopened.entries.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: try AppPaths.audioURL(filename: "deleted.m4a").path))
        }
    }

}
