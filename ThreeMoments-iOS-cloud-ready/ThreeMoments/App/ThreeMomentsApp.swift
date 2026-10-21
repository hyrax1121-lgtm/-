import SwiftUI

@main
@MainActor
struct ThreeMomentsApp: App {
    @StateObject private var application = ApplicationModel()
    init() { BackupScheduler.shared.register() }
    var body: some Scene {
        WindowGroup {
            Group {
                if let store = application.store, let backup = application.backup {
                    RootView(store: store, backup: backup)
                } else {
                    ContentUnavailableView {
                        Label("暂时无法打开日记", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(application.errorMessage ?? "请重新打开 App。原有记录不会自动清除。")
                    } actions: {
                        Button("重试") { application.load() }
                    }
                }
            }
            .tint(Palette.ink)
            .preferredColorScheme(.light)
        }
    }
}

@MainActor
final class ApplicationModel: ObservableObject {
    @Published var store: DiaryStore?
    @Published var backup: BackupService?
    @Published var errorMessage: String?
    init() { load() }
    func load() {
        // Hosted XCTest must never open or back up a real diary before the test sandbox is set.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        do {
            let loaded = try DiaryStore()
            store = loaded
            backup = BackupService(store: loaded)
            BackupScheduler.shared.backup = backup
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
