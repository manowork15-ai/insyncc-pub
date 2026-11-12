import Foundation

/// How entries are named and organised in Google Drive.
///
///     <Your folder>/
///       2026/
///         11 November/
///           2026-11-12 Thu 21.30 - Thursday Evening.mov
///
/// Title, mood, tags, duration and recording time are also kept in the file's
/// `appProperties`, so the app can rebuild its library from Drive alone.
enum DiaryLayout {
    static let appTag = "videodiary"
    static let mimeType = "video/quicktime"

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "yyyy-MM-dd EEE HH.mm"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "MM LLLL"
        return f
    }()

    private static let iso = ISO8601DateFormatter()

    static func folderPath(for date: Date) -> [String] {
        let year = Calendar.current.component(.year, from: date)
        return [String(year), monthFormatter.string(from: date)]
    }

    static func fileName(title: String, date: Date) -> String {
        let stamp = stampFormatter.string(from: date)
        let clean = sanitize(title)
        return clean.isEmpty ? "\(stamp).mov" : "\(stamp) - \(clean).mov"
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = s.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80))
    }

    static func suggestedTitle(for date: Date) -> String {
        let weekday = date.formatted(.dateTime.weekday(.wide))
        let hour = Calendar.current.component(.hour, from: date)
        let part: String
        switch hour {
        case 5..<12: part = "Morning"
        case 12..<17: part = "Afternoon"
        case 17..<22: part = "Evening"
        default: part = "Night"
        }
        return "\(weekday) \(part)"
    }

    /// Example path shown in onboarding and settings.
    static func examplePath(root: String, date: Date = Date()) -> String {
        ([root] + folderPath(for: date) + [fileName(title: suggestedTitle(for: date), date: date)])
            .joined(separator: " › ")
    }

    // MARK: Drive metadata

    /// Drive limits each appProperty to 124 bytes (key + value, UTF-8).
    private static func fit(_ value: String, key: String) -> String {
        let budget = 124 - key.utf8.count
        var out = value
        while out.utf8.count > budget { out.removeLast() }
        return out
    }

    static func appProperties(for e: DiaryEntry) -> [String: Any] {
        [
            "app": appTag,
            "localID": e.id,
            "recordedAt": iso.string(from: e.recordedAt),
            "duration": String(format: "%.1f", e.duration),
            "title": fit(e.title, key: "title"),
            "tags": fit(e.tags.joined(separator: ","), key: "tags"),
            "mood": e.mood.map { $0.rawValue as Any } ?? NSNull(),
        ]
    }

    static func metadata(for e: DiaryEntry) -> [String: Any] {
        [
            "name": fileName(title: e.displayTitle, date: e.recordedAt),
            "description": e.notes,
            "appProperties": appProperties(for: e),
        ]
    }

    static func entry(from file: DriveFile) -> DiaryEntry? {
        let p = file.appProperties ?? [:]
        guard p["app"] == appTag else { return nil }
        let recordedAt = p["recordedAt"].flatMap { iso.date(from: $0) } ?? file.createdTime ?? Date()
        let duration = p["duration"].flatMap(Double.init)
            ?? file.videoMediaMetadata?.durationMillis.flatMap(Double.init).map { $0 / 1000 }
            ?? 0
        return DiaryEntry(
            id: p["localID"] ?? file.id,
            title: p["title"] ?? "",
            mood: p["mood"].flatMap(Mood.init(rawValue:)),
            tags: (p["tags"] ?? "").split(separator: ",").map(String.init),
            notes: file.description ?? "",
            recordedAt: recordedAt,
            duration: duration,
            sizeBytes: file.size.flatMap { Int64($0) } ?? 0,
            driveFileID: file.id,
            webViewLink: file.webViewLink,
            thumbnailLink: file.thumbnailLink,
            uploadSessionURL: nil,
            localFileName: nil,
            sync: .synced
        )
    }
}
