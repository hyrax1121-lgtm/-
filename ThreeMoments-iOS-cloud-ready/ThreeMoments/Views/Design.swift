import SwiftUI

enum Palette {
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let ink = Color(red: 0.19, green: 0.27, blue: 0.23)
    static let muted = Color(red: 0.43, green: 0.46, blue: 0.42)
    static let line = Color(red: 0.85, green: 0.87, blue: 0.82)
}

enum EntryKind: String, CaseIterable, Identifiable {
    case unsorted, thought, quote, detail
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unsorted: return "待分类"
        case .thought: return "一个想法"
        case .quote: return "说过的话"
        case .detail: return "一个细节"
        }
    }
    var icon: String {
        switch self {
        case .unsorted: return "tray"
        case .thought: return "lightbulb"
        case .quote: return "quote.bubble"
        case .detail: return "leaf"
        }
    }
}

enum DisplayDate {
    static func key(_ date: Date) -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }
    static func date(_ key: String) -> Date {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.date(from: key) ?? Date()
    }
    static func label(_ key: String) -> String {
        date(key).formatted(.dateTime.year().month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }
}

struct PaperCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line, lineWidth: 0.5))
    }
}

struct Notice: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isStaticText)
    }
}

@MainActor
struct EntryRow: View {
    let entry: DiaryEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(EntryKind(rawValue: entry.type)?.title ?? "待分类", systemImage: EntryKind(rawValue: entry.type)?.icon ?? "tray")
                if entry.isBackfilled { Text("补记") }
                if entry.audioFilename != nil { Image(systemName: "waveform") }
                Spacer()
                Text(entry.createdAt, style: .time)
            }
            .font(.caption).foregroundStyle(Palette.muted)
            Text(entry.content.isEmpty ? "录音已保存，打开后可转写或补充文字。" : entry.content)
                .font(.body).foregroundStyle(Palette.ink).lineLimit(4)
                .multilineTextAlignment(.leading)
            if let speaker = entry.speaker, !speaker.isEmpty {
                Text(speaker).font(.caption).foregroundStyle(Palette.muted)
            }
        }.padding(.vertical, 6)
    }
}
