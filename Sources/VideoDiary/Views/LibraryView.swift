import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var sync: SyncEngine
    let route: Route
    @State private var search = ""
    @State private var moodFilter: Mood?
    @State private var pendingDelete: DiaryEntry?

    static func entries(for route: Route, in store: EntryStore) -> [DiaryEntry] {
        switch route {
        case .month(let y, let m):
            return store.entries.filter { MonthKey(date: $0.recordedAt) == MonthKey(year: y, month: m) }
        default:
            return store.entries
        }
    }

    private var filtered: [DiaryEntry] {
        var list = Self.entries(for: route, in: store)
        if let moodFilter { list = list.filter { $0.mood == moodFilter } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        let needle = q.hasPrefix("#") ? String(q.dropFirst()) : q
        return list.filter { e in
            e.displayTitle.lowercased().contains(needle)
                || e.notes.lowercased().contains(needle)
                || e.tags.contains { $0.lowercased().contains(needle) }
                || e.recordedAt.formatted(date: .complete, time: .omitted).lowercased().contains(needle)
        }
    }

    private struct MonthSection: Identifiable {
        let key: MonthKey
        let entries: [DiaryEntry]
        var id: MonthKey { key }
    }

    private var sections: [MonthSection] {
        Dictionary(grouping: filtered) { MonthKey(date: $0.recordedAt) }
            .map { MonthSection(key: $0.key, entries: $0.value) }
            .sorted { $0.key > $1.key }
    }

    private var title: String {
        if case .month(let y, let m) = route { return MonthKey(year: y, month: m).title }
        return "All Entries"
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyLibrary
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if case .all = route, search.isEmpty, moodFilter == nil {
                            StatsHeader()
                            if !store.onThisDay.isEmpty { OnThisDay(entries: store.onThisDay) }
                        }

                        if filtered.isEmpty {
                            ContentUnavailableView.search(text: search)
                                .frame(maxWidth: .infinity, minHeight: 240)
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 18)],
                                  alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.entries) { entry in
                                        EntryCard(entry: entry)
                                            .onTapGesture { model.libraryPath.append(entry.id) }
                                            .contextMenu { menu(for: entry) }
                                    }
                                } header: {
                                    if sections.count > 1 || route == .all {
                                        SectionHeader(title: section.key.title, entries: section.entries)
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $search, placement: .toolbar, prompt: "Search titles, notes, #tags")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Mood", selection: $moodFilter) {
                        Text("Any mood").tag(Mood?.none)
                        ForEach(Mood.allCases) { Text("\($0.emoji) \($0.label)").tag(Mood?.some($0)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: moodFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter by mood")

                Button {
                    Task { await sync.refresh() }
                } label: {
                    if sync.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help("Refresh from Google Drive (⌘R)")
                .disabled(sync.isRefreshing)

                Button {
                    model.startNewEntry()
                } label: {
                    Label("New Entry", systemImage: "record.circle")
                }
                .help("New Entry (⌘N)")
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.displayTitle ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { entry in
            Button("Move to Trash", role: .destructive) { model.delete(entry) }
        } message: { entry in
            Text(entry.driveFileID == nil
                 ? "This recording hasn't been uploaded yet and will be permanently deleted."
                 : "The video will be moved to your Google Drive trash, where you can restore it for 30 days.")
        }
    }

    @ViewBuilder
    private func menu(for entry: DiaryEntry) -> some View {
        Button("Open") { model.libraryPath.append(entry.id) }
        if let link = entry.webViewLink, let url = URL(string: link) {
            Button("Open in Google Drive") { NSWorkspace.shared.open(url) }
        }
        if let local = entry.localVideoURL {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([local]) }
        }
        if case .failed = entry.sync {
            Button("Retry Upload") { sync.retryAll() }
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = entry }
            .disabled(entry.isUploading)
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Your diary is empty", systemImage: "video.badge.plus")
        } description: {
            Text(sync.isRefreshing ? "Checking Google Drive for earlier entries…" : "Record your first entry. It only takes a minute.")
        } actions: {
            Button("Record an Entry") { model.startNewEntry() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let entries: [DiaryEntry]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries") · \(entries.reduce(0) { $0 + $1.duration }.summaryString)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

private struct StatsHeader: View {
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            stat(value: "\(store.currentStreak)", label: store.currentStreak == 1 ? "day streak" : "day streak", icon: "flame.fill", tint: .orange)
            stat(value: "\(store.entries.count)", label: store.entries.count == 1 ? "entry" : "entries", icon: "film.stack", tint: .blue)
            stat(value: store.totalDuration.summaryString, label: "recorded", icon: "clock.fill", tint: .purple)
            Spacer()
            if !store.recordedToday {
                Button {
                    model.startNewEntry()
                } label: {
                    Label("Record today's entry", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
        }
    }

    private func stat(value: String, label: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.title2.bold()).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

private struct OnThisDay: View {
    @EnvironmentObject private var model: AppModel
    let entries: [DiaryEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("On this day", systemImage: "clock.arrow.circlepath").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(entries) { entry in
                        Button { model.libraryPath.append(entry.id) } label: {
                            HStack(spacing: 10) {
                                EntryThumbnail(entry: entry)
                                    .frame(width: 96, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(yearsAgo(entry)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(entry.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func yearsAgo(_ entry: DiaryEntry) -> String {
        let years = Calendar.current.dateComponents([.year], from: entry.recordedAt, to: Date()).year ?? 1
        return years <= 1 ? "1 year ago" : "\(years) years ago"
    }
}

struct EntryCard: View {
    let entry: DiaryEntry
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                EntryThumbnail(entry: entry)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .scaleEffect(hovering ? 1.03 : 1)

                if hovering {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .transition(.opacity)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let mood = entry.mood {
                    Text(mood.emoji).font(.title3).padding(6)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) { SyncBadge(entry: entry).padding(8) }
            .overlay(alignment: .bottomTrailing) {
                Text(entry.duration.clockString)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 10 : 4, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle).font(.headline).lineLimit(1)
                Text(entry.recordedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !entry.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(entry.tags.prefix(3), id: \.self) { TagChip(text: $0) }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
