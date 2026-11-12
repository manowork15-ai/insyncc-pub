import Foundation

/// The local library index. Persisted as JSON; Drive is the source of truth for synced entries.
@MainActor
final class EntryStore: ObservableObject {
    @Published private(set) var entries: [DiaryEntry] = []

    init() {
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.entriesFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var loaded = try? decoder.decode([DiaryEntry].self, from: data) else { return }
        // An upload interrupted by quitting resumes from its saved session.
        for i in loaded.indices where loaded[i].isUploading { loaded[i].sync = .pending }
        entries = loaded.sorted { $0.recordedAt > $1.recordedAt }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: AppPaths.entriesFile, options: .atomic)
    }

    // MARK: Mutation

    func entry(_ id: String) -> DiaryEntry? {
        entries.first { $0.id == id }
    }

    func add(_ entry: DiaryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.recordedAt > $1.recordedAt }
        save()
    }

    func update(_ id: String, persist: Bool = true, _ change: (inout DiaryEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        if persist { save() }
    }

    func remove(_ id: String) {
        guard let entry = entry(id) else { return }
        let fm = FileManager.default
        if let name = entry.localFileName { try? fm.removeItem(at: AppPaths.recordings.appendingPathComponent(name)) }
        try? fm.removeItem(at: AppPaths.downloadURL(for: id))
        try? fm.removeItem(at: AppPaths.thumbnailURL(for: id))
        entries.removeAll { $0.id == id }
        save()
    }

    /// Folds a full Drive listing into the local index.
    /// - Parameter knownBefore: Drive IDs that were synced when the listing started; only these
    ///   may be dropped if missing (so an upload finishing mid-refresh isn't lost).
    func merge(remote files: [DriveFile], knownBefore: Set<String>) {
        var byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()

        for file in files {
            guard let incoming = DiaryLayout.entry(from: file) else { continue }
            seen.insert(file.id)
            if var existing = byID[incoming.id] {
                existing.driveFileID = file.id
                existing.webViewLink = incoming.webViewLink
                existing.thumbnailLink = incoming.thumbnailLink
                if incoming.sizeBytes > 0 { existing.sizeBytes = incoming.sizeBytes }
                if !existing.needsMetadataPush {
                    existing.title = incoming.title
                    existing.mood = incoming.mood
                    existing.tags = incoming.tags
                    existing.notes = incoming.notes
                }
                if !existing.isUploading { existing.sync = .synced }
                byID[incoming.id] = existing
            } else {
                byID[incoming.id] = incoming
            }
        }

        for (id, entry) in byID {
            guard let driveID = entry.driveFileID, knownBefore.contains(driveID), !seen.contains(driveID) else { continue }
            // Deleted (or trashed) in Google Drive.
            try? FileManager.default.removeItem(at: AppPaths.downloadURL(for: id))
            byID[id] = nil
        }

        entries = byID.values.sorted { $0.recordedAt > $1.recordedAt }
        save()
    }

    // MARK: Derived

    var syncedDriveIDs: Set<String> {
        Set(entries.compactMap { $0.sync == .synced ? $0.driveFileID : nil })
    }

    struct MonthCount: Identifiable {
        let key: MonthKey
        let count: Int
        var id: MonthKey { key }
    }

    var months: [MonthCount] {
        let grouped = Dictionary(grouping: entries) { MonthKey(date: $0.recordedAt) }
        return grouped.map { MonthCount(key: $0.key, count: $0.value.count) }.sorted { $0.key > $1.key }
    }

    var totalDuration: TimeInterval { entries.reduce(0) { $0 + $1.duration } }

    var recordedToday: Bool {
        entries.contains { Calendar.current.isDateInToday($0.recordedAt) }
    }

    /// Consecutive days with at least one entry, ending today (or yesterday, so the streak
    /// doesn't look broken before you've recorded today).
    var currentStreak: Int {
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.recordedAt) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    /// Entries recorded on today's date in previous years.
    var onThisDay: [DiaryEntry] {
        let cal = Calendar.current
        let today = cal.dateComponents([.year, .month, .day], from: Date())
        return entries.filter {
            let c = cal.dateComponents([.year, .month, .day], from: $0.recordedAt)
            return c.month == today.month && c.day == today.day && (c.year ?? 0) < (today.year ?? 0)
        }
    }

    /// Most-used tags first.
    var popularTags: [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for tag in entries.flatMap(\.tags) {
            let key = tag.lowercased()
            counts[key] = (counts[key]?.name ?? tag, (counts[key]?.count ?? 0) + 1)
        }
        return counts.values.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }.map(\.name)
    }

    func neighbours(of id: String, in list: [DiaryEntry]) -> (newer: DiaryEntry?, older: DiaryEntry?) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
        return (i > 0 ? list[i - 1] : nil, i + 1 < list.count ? list[i + 1] : nil)
    }
}
