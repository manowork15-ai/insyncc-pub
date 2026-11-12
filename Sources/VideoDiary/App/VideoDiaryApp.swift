import SwiftUI

@main
struct VideoDiaryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        Prefs.registerDefaults()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        Window("Video Diary", id: "main") {
            RootView()
                .withAppEnvironment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Entry") { model.startNewEntry() }
                    .keyboardShortcut("n")
                    .disabled(!model.hasOnboarded)
            }
            CommandMenu("Diary") {
                Button("All Entries") { model.route = .all }
                    .keyboardShortcut("l")
                Button("Refresh from Google Drive") { Task { await model.sync.refresh() } }
                    .keyboardShortcut("r")
                Button("Retry Failed Uploads") { model.sync.retryAll() }
            }
        }

        Settings {
            SettingsView()
                .withAppEnvironment(model)
        }
    }
}

extension View {
    func withAppEnvironment(_ model: AppModel) -> some View {
        environmentObject(model)
            .environmentObject(model.auth)
            .environmentObject(model.store)
            .environmentObject(model.sync)
            .environmentObject(model.camera)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Reminders.refresh()
    }

    /// Closing the window shouldn't stop an upload in progress; the app keeps running in the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
