import SwiftUI

@MainActor
final class FolderBrowser: ObservableObject {
    struct Crumb: Hashable { let id: String; let name: String }

    @Published var trail = [Crumb(id: "root", name: "My Drive")]
    @Published var folders: [DriveFile] = []
    @Published var isLoading = false
    @Published var error: String?

    private let drive: DriveClient

    init(drive: DriveClient) { self.drive = drive }

    var current: Crumb { trail[trail.count - 1] }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            folders = try await drive.listFolders(in: current.id)
        } catch {
            folders = []
            self.error = error.localizedDescription
        }
    }

    func open(_ folder: DriveFile) async {
        trail.append(Crumb(id: folder.id, name: folder.name))
        await load()
    }

    func jump(to crumb: Crumb) async {
        guard let index = trail.firstIndex(of: crumb) else { return }
        trail = Array(trail.prefix(through: index))
        await load()
    }

    func createFolder(named name: String) async -> DriveFile? {
        do {
            let folder = try await drive.createFolder(named: name, in: current.id)
            await load()
            return folder
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

/// Browse your Google Drive and choose (or create) the folder diary entries go into.
struct FolderPickerView: View {
    @StateObject private var browser: FolderBrowser
    @State private var selection: String?
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    let onChoose: (_ id: String, _ name: String) -> Void

    init(drive: DriveClient, onChoose: @escaping (_ id: String, _ name: String) -> Void) {
        _browser = StateObject(wrappedValue: FolderBrowser(drive: drive))
        self.onChoose = onChoose
    }

    private var selectedFolder: DriveFile? { browser.folders.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Breadcrumbs
            HStack(spacing: 4) {
                ForEach(browser.trail, id: \.self) { crumb in
                    if crumb != browser.trail.first { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    Button(crumb.name) { Task { await browser.jump(to: crumb) } }
                        .buttonStyle(.plain)
                        .fontWeight(crumb == browser.current ? .semibold : .regular)
                        .foregroundStyle(crumb == browser.current ? .primary : .secondary)
                }
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
            }
            .font(.callout)

            List(selection: $selection) {
                ForEach(browser.folders) { folder in
                    Label(folder.name, systemImage: "folder.fill")
                        .tag(folder.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { Task { await browser.open(folder) } }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(minHeight: 200)
            .overlay {
                if let error = browser.error {
                    Text(error).foregroundStyle(.red).padding()
                } else if !browser.isLoading && browser.folders.isEmpty {
                    Text("No folders here").foregroundStyle(.secondary)
                }
            }

            Text("Double-click a folder to open it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    newFolderName = "Video Diary"
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Spacer()
                if let folder = selectedFolder {
                    Button("Use “\(folder.name)”") { onChoose(folder.id, folder.name) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Use “\(browser.current.name)”") { onChoose(browser.current.id, browser.current.name) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await browser.load() }
        .alert("New folder in “\(browser.current.name)”", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task {
                    if let folder = await browser.createFolder(named: name) { selection = folder.id }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
