import Foundation
import Network

/// Background upload queue and library refresh. Uploads are resumable and survive
/// quitting the app, sleeping, or losing Wi-Fi: each entry keeps its Drive upload session.
@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var isRefreshing = false
    @Published private(set) var isWorking = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isOnline = true

    private let store: EntryStore
    private let drive: DriveClient
    private let auth: GoogleAuth
    private var worker: Task<Void, Never>?
    private var runAgain = false
    private var retryTask: Task<Void, Never>?
    private var folderCache: [String: String] = [:]
    private let monitor = NWPathMonitor()

    init(store: EntryStore, drive: DriveClient, auth: GoogleAuth) {
        self.store = store
        self.drive = drive
        self.auth = auth
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let cameBack = online && !self.isOnline
                self.isOnline = online
                if cameBack { self.kick() }
            }
        }
        monitor.start(queue: .main)
    }

    var isConfigured: Bool { auth.isSignedIn && Prefs.rootFolder != nil }

    var pendingUploads: [DiaryEntry] { store.entries.filter(\.needsUpload) }

    var failedUploads: [DiaryEntry] {
        store.entries.filter { if case .failed = $0.sync { return true } else { return false } }
    }

    /// Combined progress across everything still uploading, 0...1.
    var uploadProgress: Double? {
        let pending = pendingUploads
        guard !pending.isEmpty else { return nil }
        let total = pending.reduce(0.0) { $0 + Double(max($1.sizeBytes, 1)) }
        let done = pending.reduce(0.0) { acc, e in
            if case .uploading(let p) = e.sync { return acc + p * Double(max(e.sizeBytes, 1)) }
            return acc
        }
        return done / total
    }

    // MARK: Queue

    func kick() {
        guard isConfigured else { return }
        if worker != nil { runAgain = true; return }
        worker = Task {
            isWorking = true
            repeat {
                runAgain = false
                await processQueue()
            } while runAgain
            isWorking = false
            worker = nil
        }
    }

    func retryAll() {
        for entry in failedUploads { store.update(entry.id) { $0.sync = .pending } }
        kick()
    }

    private func processQueue() async {
        var hadFailure = false
        let ids = store.entries.filter { $0.needsUpload || $0.needsMetadataPush }.map(\.id).reversed() // oldest first
        for id in ids {
            guard isConfigured, let entry = store.entry(id) else { continue }
            do {
                if entry.needsUpload {
                    try await upload(entry)
                } else if entry.needsMetadataPush {
                    try await pushMetadata(entry)
                }
                lastError = nil
            } catch is CancellationError {
                return
            } catch {
                hadFailure = true
                lastError = error.localizedDescription
                store.update(id) {
                    if $0.needsUpload { $0.sync = .failed(message: error.localizedDescription) }
                }
                if case .reauthRequired? = error as? AuthError { return }
            }
        }
        if hadFailure { scheduleRetry() }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            retryAll()
        }
    }

    private func upload(_ entry: DiaryEntry) async throws {
        guard let name = entry.localFileName else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The recording is missing on this Mac."])
        }
        let fileURL = AppPaths.recordings.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The recording is missing on this Mac."])
        }
        let size = AppPaths.size(of: fileURL)
        let id = entry.id
        store.update(id) { $0.sync = .uploading(progress: 0); $0.sizeBytes = size }

        var sessionURL = entry.uploadSessionURL
        if sessionURL == nil {
            let parent = try await folder(for: entry.recordedAt)
            var metadata = DiaryLayout.metadata(for: entry)
            metadata["parents"] = [parent]
            metadata["mimeType"] = DiaryLayout.mimeType
            if let thumb = try? Data(contentsOf: AppPaths.thumbnailURL(for: id)) {
                metadata["contentHints"] = ["thumbnail": ["image": GoogleAuth.base64URL(thumb), "mimeType": "image/jpeg"]]
            }
            let url = try await drive.startResumableUpload(metadata: metadata, mimeType: DiaryLayout.mimeType, length: size)
            sessionURL = url
            store.update(id) { $0.uploadSessionURL = url }
        }

        let file: DriveFile
        do {
            file = try await drive.upload(fileURL: fileURL, session: sessionURL!, total: size) { @Sendable [weak self] p in
                Task { @MainActor in
                    self?.store.update(id, persist: false) { if $0.isUploading { $0.sync = .uploading(progress: p) } }
                }
            }
        } catch DriveError.uploadSessionExpired {
            store.update(id) { $0.uploadSessionURL = nil; $0.sync = .pending }
            runAgain = true
            return
        }

        store.update(id) {
            $0.driveFileID = file.id
            $0.webViewLink = file.webViewLink
            $0.thumbnailLink = file.thumbnailLink
            $0.uploadSessionURL = nil
            $0.sync = .synced
        }

        // Metadata edited while uploading? Push it now.
        if let latest = store.entry(id), latest.needsMetadataPush { try await pushMetadata(latest) }

        if !UserDefaults.standard.bool(forKey: Prefs.keepLocal) {
            try? FileManager.default.removeItem(at: fileURL)
            store.update(id) { $0.localFileName = nil }
        }
    }

    private func pushMetadata(_ entry: DiaryEntry) async throws {
        guard let fileID = entry.driveFileID else { return }
        let file = try await drive.updateFile(id: fileID, metadata: DiaryLayout.metadata(for: entry))
        store.update(entry.id) {
            $0.needsMetadataPush = false
            $0.webViewLink = file.webViewLink ?? $0.webViewLink
        }
    }

    /// Finds or creates `<root>/<year>/<MM Month>` and returns its ID.
    private func folder(for date: Date) async throws -> String {
        guard let root = Prefs.rootFolder else { throw AuthError.notSignedIn }
        var parent = root.id
        for component in DiaryLayout.folderPath(for: date) {
            let key = "\(parent)/\(component)"
            if let cached = folderCache[key] {
                parent = cached
            } else {
                let id = try await drive.findOrCreateFolder(named: component, in: parent)
                folderCache[key] = id
                parent = id
            }
        }
        return parent
    }

    func resetFolderCache() {
        folderCache = [:]
    }

    // MARK: Library

    func refresh() async {
        guard auth.isSignedIn, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            if auth.accountEmail == nil, let about = try? await drive.about() {
                auth.setAccount(name: about.user.displayName, email: about.user.emailAddress)
            }
            let known = store.syncedDriveIDs
            let files = try await drive.listDiaryFiles()
            store.merge(remote: files, knownBefore: known)
            lastRefresh = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        kick()
    }

    func edit(_ id: String, draft: EntryDraft) {
        store.update(id) {
            $0.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.mood = draft.mood
            $0.tags = draft.tags
            $0.notes = draft.notes
            $0.needsMetadataPush = true
        }
        kick()
    }

    func delete(_ entry: DiaryEntry) async throws {
        if let fileID = entry.driveFileID {
            try await drive.trash(id: fileID)
        }
        store.remove(entry.id)
    }
}
