# Native diary storage and backups

Minimum target: iOS 17. The store uses a local-only SwiftData ModelContainer with autosave disabled; writes happen explicitly and roll back pending model changes on failure. No account, server, or CloudKit container is required.

## Interfaces used by the app

- `DiaryStore(inMemory: Bool = false) throws`: a MainActor ObservableObject with published read-only `entries` and `settings`. `container` and `context` are available for SwiftUI integration. An in-memory store still uses the normal settings/draft/audio paths; it is intended for isolated test processes, not a second live diary.
- `EntrySnapshot(...)`: a mutable Codable value suitable for form state. All parameters have defaults. `DiaryEntry` is the persisted SwiftData model. `store.snapshot(for:)` creates an editable copy.
- `add(snapshot:)`, `upsert(_ snapshot:)`, `update(entry:using:)`, `delete(id:)`, `deleteEntry(id:)`, `deleteAll()`, and `reload()` throw. Update refreshes `updatedAt` while restoration preserves original timestamps. An existing nonnil `transcriptRaw` cannot be changed or removed through normal editing; editing `content` is allowed. Deleting the record deletes the original transcript too.
- `saveDraft(_:) throws`, `loadDraft() -> String`, `clearDraft() throws` persist a plain text capture draft. A successful capture should clear its draft; errors must be shown in the UI.
- `updateSettings(_:) throws` validates and atomically saves the new settings. Settings are read-only from outside the store; copy/edit/save them rather than binding directly to storage.
- `AppPaths.audioDirectory: URL` is the local recording folder. `AppPaths.ensureDirectories()` and `AppPaths.audioURL(filename:)` throw. Only a bare safe filename is stored in the model. Newly recorded audio should use UUID filenames.

`DiarySettings` has `reminderEnabled` (false until enabled by the user), `reminderTime` (`HH:mm`, default `21:00`), `automaticBackupEnabled` (true), and `backupIntervalDays` (7). Enabling a setting alone does not schedule a notification: the app must request permission and apply it through its notification service, including after a settings restore.

## BackupService

`BackupService(store:)` is a MainActor ObservableObject. Published properties: `statusText`, `selectedFolderName`, `lastSuccessfulBackupAt`, `lastAttemptAt`, and `lastError`.

- `chooseFolder(url:) throws` receives a system folder picker's URL. It tests writability and saves a local security-scoped bookmark. A location inside the app's own container is rejected because uninstalling would erase it. The bookmark is never exported.
- `backupNow() throws -> URL` writes a new uniquely named folder into the selected destination. It prepares a hidden partial folder, reads and checks the completed records/audio, then renames it to its final name. Previous backups are retained. A failure does not claim successful backup.
- `backupIfDue() async` checks when the app becomes active. It runs only when enabled and at least the configured number of days have passed since the last successful backup. It retries after failure, throttled to once a minute. This is a foreground catch-up; it does not promise a fixed weekly background execution time.
- `exportRecordsJSON() throws -> URL` produces a temporary share file without requiring a backup destination. This contains records, settings, original transcripts, and audio references, **not audio bytes**.
- `exportMarkdown() throws -> URL` produces a full plain Markdown text export. Audio is named, not bundled. Temporary share files are cleared on the next app launch and by delete-all.
- `prepareImport(from:) throws -> ImportPreview` accepts either a backup folder or a records JSON file. All JSON, metadata, and expected audio are checked before any local changes. `summaryText` is suitable for a confirmation dialog. The preview holds the attachment bytes, so the external provider need not remain open during confirmation.
- `restore(_ preview:) throws -> ImportReport` merges after confirmation. `report.summaryText` is suitable for user feedback. `restore(from:)` is a convenience that skips a separate preview presentation; the UI should use the two-step flow.

The complete folder layout is:

```
三件事日记-<timestamp>-<suffix>/
  records.json
  说明.txt
  days/2026-10-20.md
  audio/<recording filename>
```

`records.json` uses `format: "three-moments"`, `version: 1`, and snake_case entry fields. `audio_ref` is the canonical audio filename, with `audio_filename` accepted as a legacy alias and a safe `audio/` prefix normalized when importing. `audio_attachments` provides explicit `audio/<filename>` relative paths, and `audio_sha256` detects altered attachment bytes. Original content is never rewritten to mark conflicts. Markdown includes the full JSON metadata under each entry for preservation.

Web version-1 exports are accepted with ISO 8601 timestamps with or without milliseconds. Optional fields default safely; invalid categories, dates, noninteger confidence values, out-of-range confidence, certainty values other than gist/verbatim, duplicate IDs, or unsafe attachment filenames fail before import. Reminder settings accept legacy `remind`/`time` and native snake_case aliases.

For an existing ID with changed content, the imported variant gets a new UUID and `conflict_of`, `restored_at`, and `conflict_source` metadata. Semantic comparison ignores these bookkeeping fields and accounts for renamed audio attachments; importing the same conflict again skips it. Both timestamps and transcript text remain intact. Missing attachments in a standalone JSON restore are explicitly disclosed. `missing_audio_ref` retains the original reference while `audio_ref` stays nil, so playback is not falsely offered. Restoring the full folder later can repair the attachment without duplicating the record. A folder with a declared playable `audio_ref` but a missing or invalid audio file is rejected as incomplete.

## Deletion and limitations

Delete uses a durable prepared/committed journal before staging attachments. A normal save failure restores staged files and rows. On the next launch, an interrupted prepared operation rolls back; a committed operation finishes removing its staged copies. An erase failure after commit is reported as partial cleanup, never as a full success. Delete-all includes local recordings, orphan audio, unsaved draft, and temporary exports. External backup folders are not erased. Crash-recovery XCTest cases are included but still require execution on a Mac.

The files are protected by iOS file protection while locked (available after first unlock). User-selected exported backups are ordinary unencrypted files. Folder provider behavior, file protection, real-device audio, and notification permissions still require iPhone testing.

This source was prepared on Windows. Neither Swift nor Xcode is available here; no native build, XCTest run, simulator run, or device verification is claimed. Run the included tests and the app's release checklist on a Mac before using it as the only copy of a diary.
