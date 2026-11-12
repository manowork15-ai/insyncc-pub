import SwiftUI

struct EntryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var sync: SyncEngine
    let entryID: String
    let route: Route

    @State private var draft = EntryDraft()
    @State private var loadedDraftFor: String?
    @State private var downloadProgress: Double?
    @State private var downloadError: String?
    @State private var confirmDelete = false

    private var entry: DiaryEntry? { store.entry(entryID) }

    var body: some View {
        if let entry {
            content(entry)
        } else {
            ContentUnavailableView("Entry not found", systemImage: "questionmark.video",
                                   description: Text("It may have been deleted in Google Drive."))
        }
    }

    private func content(_ entry: DiaryEntry) -> some View {
        let neighbours = store.neighbours(of: entryID, in: LibraryView.entries(for: route, in: store))
        let isDirty = draft != EntryDraft(entry: entry)

        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                player(entry)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let mood = entry.mood { Text(mood.emoji).font(.largeTitle) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayTitle).font(.title.bold())
                        Text(entry.recordedAt.formatted(date: .complete, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusLine(entry)
                }
            }
            .padding(20)

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    MetadataForm(draft: $draft, titlePlaceholder: DiaryLayout.suggestedTitle(for: entry.recordedAt),
                                 suggestedTags: store.popularTags)
                        .padding(20)
                }
                Divider()
                HStack {
                    Button("Revert") { draft = EntryDraft(entry: entry) }
                        .disabled(!isDirty)
                    Spacer()
                    Button("Save Changes") {
                        sync.edit(entry.id, draft: draft)
                        model.showToast(entry.driveFileID == nil ? "Saved." : "Saved. Updating Google Drive…")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
                }
                .padding(16)
            }
            .frame(width: 340)
        }
        .navigationTitle(entry.displayTitle)
        .onAppear { loadDraft(entry) }
        .onChange(of: entryID) { _, _ in
            if let e = self.entry { loadDraft(e) }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { if let n = neighbours.newer { go(n) } } label: { Label("Newer", systemImage: "chevron.up") }
                    .disabled(neighbours.newer == nil)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .help("Newer entry (⌘↑)")
                Button { if let o = neighbours.older { go(o) } } label: { Label("Older", systemImage: "chevron.down") }
                    .disabled(neighbours.older == nil)
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .help("Older entry (⌘↓)")

                Menu {
                    if let link = entry.webViewLink, let url = URL(string: link) {
                        Button("Open in Google Drive") { NSWorkspace.shared.open(url) }
                    }
                    if let local = entry.localVideoURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([local]) }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .disabled(entry.isUploading)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete “\(entry.displayTitle)”?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { model.delete(entry) }
        } message: {
            Text(entry.driveFileID == nil
                 ? "This recording hasn't been uploaded yet and will be permanently deleted."
                 : "The video will be moved to your Google Drive trash, where you can restore it for 30 days.")
        }
    }

    private func go(_ other: DiaryEntry) {
        guard !model.libraryPath.isEmpty else { return }
        model.libraryPath[model.libraryPath.count - 1] = other.id
    }

    private func loadDraft(_ entry: DiaryEntry) {
        guard loadedDraftFor != entry.id else { return }
        loadedDraftFor = entry.id
        draft = EntryDraft(entry: entry)
        downloadProgress = nil
        downloadError = nil
    }

    @ViewBuilder
    private func player(_ entry: DiaryEntry) -> some View {
        if let url = entry.localVideoURL {
            PlayerView(url: url, autoplay: true)
        } else {
            ZStack {
                EntryThumbnail(entry: entry).blur(radius: 8).overlay(.black.opacity(0.35))
                VStack(spacing: 12) {
                    if let error = downloadError {
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                        Text(error).multilineTextAlignment(.center)
                        Button("Try Again") { Task { await download(entry) } }
                    } else {
                        ProgressView(value: downloadProgress ?? 0)
                            .progressViewStyle(.circular)
                            .controlSize(.large)
                        Text("Loading from Google Drive… \(Int((downloadProgress ?? 0) * 100))%")
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(.white)
                .padding()
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .task(id: entry.id) { await download(entry) }
        }
    }

    private func download(_ entry: DiaryEntry) async {
        guard let fileID = entry.driveFileID else {
            downloadError = "This recording isn't on this Mac or in Google Drive."
            return
        }
        downloadError = nil
        downloadProgress = 0
        do {
            let id = entry.id
            _ = try await model.drive.download(fileID: fileID, to: AppPaths.downloadURL(for: id),
                                               expectedSize: entry.sizeBytes) { @Sendable p in
                Task { @MainActor in if loadedDraftFor == id { downloadProgress = p } }
            }
            // Nudge the store so `localVideoURL` is re-evaluated.
            store.update(id, persist: false) { _ in }
            downloadProgress = nil
        } catch {
            downloadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func statusLine(_ entry: DiaryEntry) -> some View {
        HStack(spacing: 6) {
            switch entry.sync {
            case .synced:
                Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
                Text("In Google Drive")
            case .pending:
                Image(systemName: "icloud.and.arrow.up")
                Text("Waiting to upload")
            case .uploading(let p):
                ProgressView(value: p).frame(width: 60)
                Text("Uploading \(Int(p * 100))%").monospacedDigit()
            case .failed(let message):
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.orange)
                Text("Upload failed").help(message)
                Button("Retry") { sync.retryAll() }.buttonStyle(.link)
            }
            Text("· \(entry.duration.clockString)")
            if entry.sizeBytes > 0 { Text("· \(entry.sizeBytes.byteString)") }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
