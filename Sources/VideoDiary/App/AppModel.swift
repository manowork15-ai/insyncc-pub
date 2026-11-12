import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    let auth: GoogleAuth
    let store: EntryStore
    let drive: DriveClient
    let sync: SyncEngine
    let camera = CameraController()

    @Published var route: Route? = .record {
        didSet { if oldValue != route { libraryPath = [] } }
    }
    @Published var libraryPath: [String] = []
    @Published var recordPhase: RecordPhase = .idle
    @Published var toast: Toast?
    @Published var hasOnboarded = UserDefaults.standard.bool(forKey: Prefs.onboarded)

    private var toastTask: Task<Void, Never>?
    private var launched = false

    init() {
        let auth = GoogleAuth()
        let store = EntryStore()
        let drive = DriveClient { force in try await auth.accessToken(forceRefresh: force) }
        self.auth = auth
        self.store = store
        self.drive = drive
        self.sync = SyncEngine(store: store, drive: drive, auth: auth)
        ThumbnailCache.shared.drive = drive
        // Open straight into the library if you've already recorded today.
        if store.recordedToday { route = .all }
    }

    func launch() async {
        guard !launched else { return }
        launched = true
        await sync.refresh()
        sync.kick()
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Prefs.onboarded)
        hasOnboarded = true
        route = .record
        Task { await sync.refresh() }
    }

    func startNewEntry() {
        route = .record
    }

    func open(_ entry: DiaryEntry) {
        if route == .record { route = .all }
        libraryPath = [entry.id]
    }

    func showToast(_ message: String, systemImage: String = "checkmark.circle.fill") {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { toast = Toast(message: message, systemImage: systemImage) }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { toast = nil }
        }
    }

    // MARK: Recording flow

    func newTakeURL() -> (id: String, url: URL) {
        let id = UUID().uuidString
        return (id, AppPaths.recordings.appendingPathComponent("\(id).mov"))
    }

    func discard(_ take: Take) {
        try? FileManager.default.removeItem(at: take.url)
        try? FileManager.default.removeItem(at: AppPaths.thumbnailURL(for: take.id))
        recordPhase = .idle
    }

    func save(_ take: Take, draft: EntryDraft) {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = DiaryEntry(
            id: take.id,
            title: title.isEmpty ? DiaryLayout.suggestedTitle(for: take.startedAt) : title,
            mood: draft.mood,
            tags: draft.tags,
            notes: draft.notes.trimmingCharacters(in: .whitespacesAndNewlines),
            recordedAt: take.startedAt,
            duration: take.duration,
            sizeBytes: AppPaths.size(of: take.url),
            localFileName: take.url.lastPathComponent,
            sync: .pending
        )
        store.add(entry)
        recordPhase = .idle
        route = .all

        if sync.isConfigured {
            showToast("Saved. Uploading to Google Drive…", systemImage: "icloud.and.arrow.up.fill")
        } else {
            showToast("Saved on this Mac. Connect Google Drive in Settings to back it up.", systemImage: "externaldrive.fill")
        }
        sync.kick()
        Reminders.refresh(recordedToday: true)
    }

    func delete(_ entry: DiaryEntry) {
        Task {
            do {
                try await sync.delete(entry)
                libraryPath.removeAll { $0 == entry.id }
                showToast("Entry moved to Google Drive trash.", systemImage: "trash.fill")
            } catch {
                showToast(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            }
        }
    }
}

/// Daily "time for your diary" nudge.
enum Reminders {
    static func refresh(recordedToday: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily-reminder"])
        guard UserDefaults.standard.bool(forKey: Prefs.reminderEnabled) else { return }

        let minutes = UserDefaults.standard.integer(forKey: Prefs.reminderMinutes)
        let content = UNMutableNotificationContent()
        content.title = "Time for today's entry"
        content.body = "Take two minutes to talk about your day."
        content.sound = .default

        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        center.add(UNNotificationRequest(identifier: "daily-reminder", content: content, trigger: trigger))
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
