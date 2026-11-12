import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.hasOnboarded {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast).id(toast.id)
            }
        }
        .task { if model.hasOnboarded { await model.launch() } }
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            switch model.route ?? .all {
            case .record:
                RecordView()
            case .all, .month:
                NavigationStack(path: $model.libraryPath) {
                    LibraryView(route: model.route ?? .all)
                        .navigationDestination(for: String.self) { id in
                            EntryDetailView(entryID: id, route: model.route ?? .all)
                        }
                }
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: EntryStore

    var body: some View {
        List(selection: $model.route) {
            Section {
                Label {
                    Text("New Entry")
                } icon: {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                }
                .tag(Route.record)

                Label("All Entries", systemImage: "square.grid.2x2")
                    .badge(store.entries.count)
                    .tag(Route.all)
            }

            if !store.months.isEmpty {
                Section("Timeline") {
                    ForEach(store.months) { month in
                        Label(month.key.title, systemImage: "calendar")
                            .badge(month.count)
                            .tag(Route.month(year: month.key.year, month: month.key.month))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarFooter()
        }
    }
}

/// Streak + backup status: the two things you want to glance at.
private struct SidebarFooter: View {
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var auth: GoogleAuth
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.currentStreak > 0 {
                HStack(spacing: 6) {
                    Text("🔥")
                    Text("\(store.currentStreak)-day streak").font(.callout.weight(.semibold))
                    Spacer()
                    if !store.recordedToday {
                        Text("Record today").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            status
                .font(.caption)
        }
        .padding(12)
    }

    @ViewBuilder
    private var status: some View {
        if !auth.isSignedIn || Prefs.rootFolder == nil {
            Button {
                openSettings()
            } label: {
                Label("Connect Google Drive to back up", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        } else if !sync.isOnline && !sync.pendingUploads.isEmpty {
            Label("Offline: \(sync.pendingUploads.count) waiting to upload", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        } else if let progress = sync.uploadProgress {
            VStack(alignment: .leading, spacing: 4) {
                let count = sync.pendingUploads.count
                Label("Uploading \(count) \(count == 1 ? "entry" : "entries")…", systemImage: "icloud.and.arrow.up")
                ProgressView(value: progress).controlSize(.small)
                if !sync.failedUploads.isEmpty {
                    Button("Retry now") { sync.retryAll() }.buttonStyle(.link)
                }
            }
            .foregroundStyle(.secondary)
        } else if sync.isRefreshing {
            Label("Syncing with Google Drive…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        } else {
            Label("All entries backed up", systemImage: "checkmark.icloud")
                .foregroundStyle(.secondary)
                .help(auth.accountEmail.map { "Signed in as \($0)" } ?? "")
        }
    }
}
