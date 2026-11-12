import Foundation

enum Mood: String, CaseIterable, Codable, Identifiable, Hashable {
    case great, good, okay, meh, rough

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .great: "🤩"
        case .good: "🙂"
        case .okay: "😐"
        case .meh: "😕"
        case .rough: "😣"
        }
    }

    var label: String { rawValue.capitalized }
}

enum SyncState: Codable, Hashable {
    /// Recorded and saved locally, waiting for its turn to upload.
    case pending
    case uploading(progress: Double)
    case synced
    case failed(message: String)
}

struct DiaryEntry: Identifiable, Codable, Hashable {
    /// Stable identifier generated when recording. Also stored in Drive `appProperties`
    /// so the same entry is recognised across launches and machines.
    var id: String
    var title: String
    var mood: Mood?
    var tags: [String]
    var notes: String
    var recordedAt: Date
    var duration: TimeInterval
    var sizeBytes: Int64

    var driveFileID: String?
    var webViewLink: String?
    var thumbnailLink: String?
    var uploadSessionURL: URL?

    /// File name inside `AppPaths.recordings`, if the original recording is on this Mac.
    var localFileName: String?
    var sync: SyncState
    /// Metadata was edited locally and still has to be written to Drive.
    var needsMetadataPush: Bool = false

    var needsUpload: Bool { driveFileID == nil }

    var isUploading: Bool {
        if case .uploading = sync { return true }
        return false
    }

    var displayTitle: String {
        title.isEmpty ? DiaryLayout.suggestedTitle(for: recordedAt) : title
    }

    /// The best playable file on this Mac: the original recording or a downloaded copy.
    var localVideoURL: URL? {
        let fm = FileManager.default
        if let name = localFileName {
            let url = AppPaths.recordings.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        let cached = AppPaths.downloadURL(for: id)
        return fm.fileExists(atPath: cached.path) ? cached : nil
    }
}

/// Editable metadata, shared by the post-recording review and the entry detail screen.
struct EntryDraft: Equatable {
    var title = ""
    var mood: Mood?
    var tagsText = ""
    var notes = ""

    init() {}

    init(entry: DiaryEntry) {
        title = entry.title
        mood = entry.mood
        tagsText = entry.tags.joined(separator: ", ")
        notes = entry.notes
    }

    var tags: [String] { EntryDraft.parseTags(tagsText) }

    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == "#" }) {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
        }
        return result
    }
}

struct Take: Equatable, Identifiable {
    let id: String
    let url: URL
    let startedAt: Date
    var duration: TimeInterval
}

enum RecordPhase: Equatable {
    case idle
    case countdown(Int)
    case recording(startedAt: Date)
    case review(Take)
}

enum Route: Hashable {
    case record
    case all
    case month(year: Int, month: Int)
}

struct MonthKey: Hashable, Comparable, Identifiable {
    let year: Int
    let month: Int

    var id: String { "\(year)-\(month)" }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(date: Date) {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        year = c.year ?? 0
        month = c.month ?? 0
    }

    var title: String {
        let comps = DateComponents(year: year, month: month, day: 1)
        guard let date = Calendar.current.date(from: comps) else { return "\(month)/\(year)" }
        return date.formatted(.dateTime.month(.wide).year())
    }

    static func < (a: MonthKey, b: MonthKey) -> Bool {
        (a.year, a.month) < (b.year, b.month)
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var systemImage: String = "checkmark.circle.fill"
}

enum Prefs {
    static let onboarded = "hasOnboarded"
    static let rootFolderID = "rootFolderID"
    static let rootFolderName = "rootFolderName"
    static let countdown = "countdownEnabled"
    static let prompts = "showPrompts"
    static let keepLocal = "keepLocalCopies"
    static let mirror = "mirrorPreview"
    static let hevc = "useHEVC"
    static let videoDevice = "videoDeviceID"
    static let audioDevice = "audioDeviceID"
    static let reminderEnabled = "reminderEnabled"
    static let reminderMinutes = "reminderMinutes"
    static let accountName = "accountName"
    static let accountEmail = "accountEmail"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            countdown: true,
            prompts: true,
            keepLocal: true,
            mirror: true,
            hevc: true,
            reminderEnabled: false,
            reminderMinutes: 21 * 60,
        ])
    }

    static var rootFolder: (id: String, name: String)? {
        let d = UserDefaults.standard
        guard let id = d.string(forKey: rootFolderID) else { return nil }
        return (id, d.string(forKey: rootFolderName) ?? "Video Diary")
    }

    static func setRootFolder(id: String, name: String) {
        UserDefaults.standard.set(id, forKey: rootFolderID)
        UserDefaults.standard.set(name, forKey: rootFolderName)
    }
}

enum AppPaths {
    private static func directory(_ base: FileManager.SearchPathDirectory, _ name: String?) -> URL {
        var url = FileManager.default.urls(for: base, in: .userDomainMask)[0]
            .appendingPathComponent("VideoDiary", isDirectory: true)
        if let name { url = url.appendingPathComponent(name, isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let support = directory(.applicationSupportDirectory, nil)
    static let recordings = directory(.applicationSupportDirectory, "Recordings")
    static let thumbnails = directory(.applicationSupportDirectory, "Thumbnails")
    static let downloads = directory(.cachesDirectory, "Downloads")

    static var entriesFile: URL { support.appendingPathComponent("entries.json") }

    static func downloadURL(for id: String) -> URL {
        downloads.appendingPathComponent("\(id).mov")
    }

    static func thumbnailURL(for id: String) -> URL {
        thumbnails.appendingPathComponent("\(id).jpg")
    }

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func directorySize(_ url: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + size(of: $1) }
    }
}

extension TimeInterval {
    /// "4:07" or "1:02:33"
    var clockString: String {
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "3h 12m" / "14m" / "45s"
    var summaryString: String {
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }
}
