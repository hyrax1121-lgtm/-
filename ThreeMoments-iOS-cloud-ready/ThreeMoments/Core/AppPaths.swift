import Foundation

enum AppPaths {
    #if DEBUG
    /// XCTest sets this only while using an in-memory model container. Production
    /// Release builds cannot redirect diary storage through this testing hook.
    static var testingRoot: URL?
    #endif
    static var root: URL {
        #if DEBUG
        if let testingRoot { return testingRoot }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThreeMoments", isDirectory: true)
    }
    static var audioDirectory: URL { root.appendingPathComponent("Audio", isDirectory: true) }
    static var database: URL { root.appendingPathComponent("Diary.store") }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }
    static var draftFile: URL { root.appendingPathComponent("draft.txt") }
    static var backupPreferencesFile: URL { root.appendingPathComponent("backup-preferences.json") }
    static var recoveryDirectory: URL { root.appendingPathComponent("PendingCleanup", isDirectory: true) }
    static var exportsDirectory: URL {
        #if DEBUG
        if let testingRoot { return testingRoot.appendingPathComponent("TestExports", isDirectory: true) }
        #endif
        return FileManager.default.temporaryDirectory.appendingPathComponent("ThreeMomentsExports", isDirectory: true)
    }

    static func ensureDirectories() throws {
        let fm = FileManager.default
        for directory in [root, audioDirectory, exportsDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        // A user-selected Files folder is the backup destination; temporary share files
        // are excluded from device backup and are cleared on the next launch.
        var exports = exportsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try exports.setResourceValues(values)
    }

    static func isSafeFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
            && URL(fileURLWithPath: name).lastPathComponent == name
    }

    static func audioURL(filename: String) throws -> URL {
        guard isSafeFilename(filename) else { throw DiaryError.invalidBackup("录音文件名无效。") }
        return audioDirectory.appendingPathComponent(filename)
    }
}

enum BackupJSON {
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(timestamp(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: text) ?? standard.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO 8601 date")
        }
        return decoder
    }
}
