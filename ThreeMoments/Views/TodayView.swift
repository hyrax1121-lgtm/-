import SwiftUI

@MainActor
struct TodayView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var voice: VoiceService
    @State private var editing: DiaryEntry?
    @State private var addingKind: EntryKind?
    @State private var showEvening = false
    private var entries: [DiaryEntry] {
        store.entries.filter { $0.date == DisplayDate.key(Date()) }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(DisplayDate.label(DisplayDate.key(Date())))
                    .font(.subheadline).foregroundStyle(Palette.muted)
                Notice(text: "有想留下的，就记一点。三栏不用填满，也不用每天都写。")
                ForEach([EntryKind.thought, .quote, .detail]) { kind in
                    PaperCard {
                        HStack {
                            Label(kind.title, systemImage: kind.icon).font(.headline)
                            Spacer()
                            Button { addingKind = kind } label: { Image(systemName: "plus").frame(width: 36, height: 36) }
                                .accessibilityLabel("添加\(kind.title)")
                        }
                        let records = entries.filter { $0.type == kind.rawValue }
                        if records.isEmpty {
                            Text(placeholder(kind)).font(.subheadline).foregroundStyle(Palette.muted)
                        } else {
                            ForEach(records) { entry in
                                Button { editing = entry } label: { EntryRow(entry: entry) }.buttonStyle(.plain)
                                if entry.id != records.last?.id { Divider() }
                            }
                        }
                    }
                }
                Button { showEvening = true } label: {
                    PaperCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("晚间补全").font(.headline)
                                Text("看看今天留下的速记，想整理时再分类。")
                                    .font(.subheadline).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                    }
                }.buttonStyle(.plain)
                let pending = entries.filter { $0.type == "unsorted" }
                if !pending.isEmpty {
                    Text("待分类").font(.headline)
                    ForEach(pending) { entry in
                        Button { editing = entry } label: { PaperCard { EntryRow(entry: entry) } }.buttonStyle(.plain)
                    }
                }
            }.padding(20)
        }
        .background(Palette.paper).navigationTitle("今天")
        .sheet(item: $editing) { EntryEditorView(store: store, voice: voice, entry: $0) }
        .sheet(item: $addingKind) { EntryEditorView(store: store, voice: voice, type: $0.rawValue) }
        .sheet(isPresented: $showEvening) { EveningView(store: store, voice: voice) }
    }

    private func placeholder(_ kind: EntryKind) -> String {
        switch kind {
        case .thought: return "今天冒出的一个念头，或者还没想明白的事。"
        case .quote: return "一句想记住的话，也可以是你自己说的。"
        case .detail: return "一个声音、一种气味，或一个很小的瞬间。"
        case .unsorted: return "先留下，稍后再分类。"
        }
    }
}

@MainActor
struct EveningView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var voice: VoiceService
    @Environment(\.dismiss) private var dismiss
    @State private var editing: DiaryEntry?
    @State private var addNew = false
    private var captures: [DiaryEntry] {
        store.entries.filter { $0.date == DisplayDate.key(Date()) && $0.captureOrigin }.sorted { $0.createdAt < $1.createdAt }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Notice(text: "这里包括已分类和待分类的全部速记。可以补几句话，也可以保持原样。")
                }
                if captures.isEmpty {
                    ContentUnavailableView("今天还没有速记", systemImage: "square.and.pencil", description: Text("现在想起什么，记一句就好。"))
                } else {
                    ForEach(captures) { entry in
                        Button { editing = entry } label: { EntryRow(entry: entry) }.buttonStyle(.plain)
                    }
                }
                Button("补充一条记录") { addNew = true }
            }
            .navigationTitle("晚间补全").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $editing) { EntryEditorView(store: store, voice: voice, entry: $0) }
            .sheet(isPresented: $addNew) { EntryEditorView(store: store, voice: voice) }
        }
    }
}
