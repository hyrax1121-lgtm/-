import SwiftUI

@MainActor
struct ReviewView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var voice: VoiceService
    @State private var month = Date()
    @State private var selectedDate = Date()
    @State private var query = ""
    @State private var selectedType = "all"
    @State private var selectedSpeaker = "all"
    @State private var searchDay: SelectedDay?
    @State private var showBackfill = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var speakers: [String] {
        Array(Set(store.entries.compactMap(\.speaker).filter { !$0.isEmpty })).sorted()
    }
    private var isSearching: Bool { !query.isEmpty || selectedType != "all" || selectedSpeaker != "all" }
    private var matches: [DiaryEntry] {
        store.entries.filter { entry in
            let categoryMatches = selectedType == "all" || entry.type == selectedType
            let personMatches = selectedSpeaker == "all" || entry.speaker == selectedSpeaker
            let haystack = [entry.content, entry.transcriptRaw, entry.basis, entry.prediction, entry.speaker, entry.myReaction].compactMap { $0 }.joined(separator: "\n")
            return categoryMatches && personMatches && (query.isEmpty || haystack.localizedCaseInsensitiveContains(query))
        }.sorted { $0.date == $1.date ? $0.createdAt < $1.createdAt : $0.date > $1.date }
    }
    private var dayKeys: Set<String> { Set(store.entries.map(\.date)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Picker("分类筛选", selection: $selectedType) {
                        Text("全部分类").tag("all")
                        ForEach(EntryKind.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("说话人筛选", selection: $selectedSpeaker) {
                        Text("全部说话人").tag("all")
                        ForEach(speakers, id: \.self) { Text($0).tag($0) }
                    }
                }.font(.subheadline).frame(maxWidth: .infinity)
                if isSearching {
                    if matches.isEmpty { ContentUnavailableView.search(text: query) }
                    ForEach(matches) { entry in
                        Button { searchDay = SelectedDay(date: entry.date) } label: {
                            PaperCard {
                                Text(DisplayDate.label(entry.date)).font(.caption).foregroundStyle(Palette.muted)
                                EntryRow(entry: entry)
                            }
                        }.buttonStyle(.plain)
                    }
                    Button("清除搜索与筛选") { query = ""; selectedType = "all"; selectedSpeaker = "all" }
                } else {
                    calendar
                    HStack {
                        Text(DisplayDate.label(DisplayDate.key(selectedDate))).font(.headline)
                        Spacer()
                        Button("补记") { showBackfill = true }
                            .disabled(Calendar.current.startOfDay(for: selectedDate) > Calendar.current.startOfDay(for: Date()))
                    }
                    DayEntriesView(store: store, voice: voice, date: DisplayDate.key(selectedDate))
                }
            }.padding(20)
        }
        .background(Palette.paper)
        .navigationTitle("回看")
        .searchable(text: $query, prompt: "搜索文字、原文或说话人")
        .sheet(item: $searchDay) { day in
            NavigationStack {
                ScrollView { DayEntriesView(store: store, voice: voice, date: day.date).padding(20) }
                    .background(Palette.paper)
                    .navigationTitle(DisplayDate.label(day.date))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { searchDay = nil } } }
            }
        }
        .sheet(isPresented: $showBackfill) { EntryEditorView(store: store, voice: voice, date: DisplayDate.key(selectedDate)) }
    }

    private var calendar: some View {
        PaperCard {
            HStack {
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上个月")
                Spacer()
                Text(month.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN")))).font(.headline)
                Spacer()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下个月")
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption).foregroundStyle(Palette.muted) }
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let key = DisplayDate.key(date)
                        let selected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        Button { selectedDate = date } label: {
                            VStack(spacing: 4) {
                                Text("\(Calendar.current.component(.day, from: date))").font(.subheadline)
                                Circle().fill(dayKeys.contains(key) ? (selected ? Color.white : Palette.ink) : Color.clear).frame(width: 4, height: 4)
                            }
                            .frame(maxWidth: .infinity).frame(height: 43)
                            .foregroundStyle(selected ? Color.white : Palette.ink)
                            .background(selected ? Palette.ink : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityLabel("\(DisplayDate.label(key))，\(dayKeys.contains(key) ? "有记录" : "没有记录")")
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    } else { Color.clear.frame(height: 43) }
                }
            }
            Notice(text: "圆点只表示当天有记录。空白的日子也可以留白。")
        }
    }

    private var monthDays: [Date?] {
        let calendar = Calendar(identifier: .gregorian)
        guard let interval = calendar.dateInterval(of: .month, for: month), let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let offset = (weekday + 5) % 7
        return Array(repeating: nil, count: offset) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: interval.start) }.map(Optional.some)
    }
    private func changeMonth(_ offset: Int) {
        if let changed = Calendar.current.date(byAdding: .month, value: offset, to: month) {
            month = changed
            if let first = Calendar.current.dateInterval(of: .month, for: changed)?.start { selectedDate = first }
        }
    }
}

private struct SelectedDay: Identifiable {
    let date: String
    var id: String { date }
}

@MainActor
struct DayEntriesView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var voice: VoiceService
    let date: String
    @ScaledMetric(relativeTo: .body) private var readingSize = 18.0
    @ScaledMetric(relativeTo: .body) private var readingSpacing = 14.0
    @State private var editing: DiaryEntry?
    private var entries: [DiaryEntry] {
        store.entries.filter { $0.date == date }.sorted { $0.createdAt < $1.createdAt }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if entries.isEmpty { Notice(text: "这一天没有记录。想起了什么，可以随时补记。") }
            ForEach(entries) { entry in
                PaperCard {
                    HStack {
                        Label(EntryKind(rawValue: entry.type)?.title ?? "待分类", systemImage: EntryKind(rawValue: entry.type)?.icon ?? "tray")
                        if entry.isBackfilled { Text("补记") }
                        Spacer()
                        Button("编辑") { editing = entry }.accessibilityLabel("编辑这条\(EntryKind(rawValue: entry.type)?.title ?? "记录")")
                    }.font(.caption).foregroundStyle(Palette.muted)
                    if entry.conflictOf != nil { Label("恢复时保留的冲突副本", systemImage: "doc.on.doc").font(.caption).foregroundStyle(Palette.muted) }
                    Text(entry.content.isEmpty ? "这条记录只有录音，可以先听一听。" : entry.content)
                        .font(.system(size: readingSize)).lineSpacing(readingSpacing)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let speaker = entry.speaker, !speaker.isEmpty {
                        Text("\(speaker) · \(entry.certainty == "verbatim" || entry.certainty == "原话" ? "原话" : entry.certainty == "gist" || entry.certainty == "大意" ? "大意" : "未标注原话或大意")")
                            .font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    metadata("当时的依据", entry.basis)
                    metadata("当时的判断", entry.prediction)
                    if let confidence = entry.confidence { Text("当时的把握：\(confidence)%").font(.subheadline).foregroundStyle(Palette.muted) }
                    metadata("当时的反应", entry.myReaction)
                    if let filename = entry.audioFilename {
                        HStack {
                            Button { voice.play(filename: filename) } label: { Label("听录音", systemImage: "play.circle") }
                            Spacer()
                            Button("停止") { voice.stopPlayback() }
                        }.font(.subheadline)
                    }
                    if entry.missingAudioRef != nil { Notice(text: "此备份未包含录音附件，文字已保留。可从完整文件夹再次恢复附件。") }
                    if let raw = entry.transcriptRaw {
                        DisclosureGroup("转写原文 · 只读") { Text(raw).font(.system(size: readingSize)).lineSpacing(readingSpacing).textSelection(.enabled).padding(.top, 8) }
                            .font(.subheadline)
                    }
                    Text("创建于 \(entry.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN"))))")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
        }
        .sheet(item: $editing) { EntryEditorView(store: store, voice: voice, entry: $0) }
        .onDisappear { voice.stopPlayback() }
    }
    @ViewBuilder private func metadata(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.caption).foregroundStyle(Palette.muted)
                Text(value).font(.system(size: readingSize)).lineSpacing(readingSpacing).textSelection(.enabled)
            }
        }
    }
}
