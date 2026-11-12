import AVFoundation
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            DriveSettings().tabItem { Label("Google Drive", systemImage: "externaldrive.badge.icloud") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "video") }
            ReminderSettings().tabItem { Label("Reminders", systemImage: "bell") }
        }
        .frame(width: 560)
        .padding(.vertical, 8)
    }
}

private struct DriveSettings: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: GoogleAuth
    @EnvironmentObject private var sync: SyncEngine
    @AppStorage(Prefs.keepLocal) private var keepLocal = true
    @AppStorage(Prefs.rootFolderName) private var folderName: String?
    @State private var choosingFolder = false
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var showHelp = false
    @State private var error: String?
    @State private var storageTick = 0

    var body: some View {
        Form {
            Section("Account") {
                if auth.isSignedIn {
                    LabeledContent("Signed in as") {
                        Text(auth.accountEmail ?? auth.accountName ?? "Google account")
                    }
                    Button("Sign Out", role: .destructive) { auth.signOut() }
                } else {
                    if !auth.hasBundledCredentials {
                        CredentialsForm(clientID: $clientID, clientSecret: $clientSecret, showHelp: $showHelp)
                    }
                    HStack {
                        Button(auth.isSigningIn ? "Waiting for browser…" : "Sign in with Google") { signIn() }
                            .disabled(auth.isSigningIn)
                        if auth.isSigningIn { Button("Cancel") { auth.cancelSignIn() } }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                }
            }

            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(folderName ?? "Not chosen").foregroundStyle(folderName == nil ? .secondary : .primary)
                        Button("Change…") { choosingFolder = true }.disabled(!auth.isSignedIn)
                    }
                }
                Text(DiaryLayout.examplePath(root: folderName ?? "Video Diary"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Organisation")
            } footer: {
                Text("New entries are filed into year and month folders. Changing the folder doesn't move existing entries; the app still finds them wherever they are in your Drive.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage on this Mac") {
                Toggle("Keep a local copy after uploading", isOn: $keepLocal)
                let _ = storageTick
                LabeledContent("Recordings", value: AppPaths.directorySize(AppPaths.recordings).byteString)
                LabeledContent("Downloaded for playback", value: AppPaths.directorySize(AppPaths.downloads).byteString)
                HStack {
                    Button("Free Up Space") { freeUpSpace() }
                        .help("Deletes local copies of entries that are safely in Google Drive")
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.support) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            clientID = auth.credentials?.clientID ?? ""
            clientSecret = auth.credentials?.clientSecret ?? ""
        }
        .sheet(isPresented: $choosingFolder) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a Google Drive folder").font(.title2.bold())
                FolderPickerView(drive: model.drive) { id, name in
                    Prefs.setRootFolder(id: id, name: name)
                    folderName = name
                    sync.resetFolderCache()
                    choosingFolder = false
                    sync.kick()
                }
                HStack { Spacer(); Button("Cancel") { choosingFolder = false }.keyboardShortcut(.cancelAction) }
            }
            .padding(20)
            .frame(width: 520, height: 460)
        }
    }

    private func signIn() {
        error = nil
        if !auth.hasBundledCredentials { auth.saveCredentials(clientID: clientID, clientSecret: clientSecret) }
        Task {
            do {
                try await auth.signIn()
                if let about = try? await model.drive.about() {
                    auth.setAccount(name: about.user.displayName, email: about.user.emailAddress)
                }
                if Prefs.rootFolder == nil {
                    choosingFolder = true
                } else {
                    await sync.refresh()
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func freeUpSpace() {
        let store = model.store
        for entry in store.entries where entry.driveFileID != nil && !entry.isUploading {
            if let name = entry.localFileName {
                try? FileManager.default.removeItem(at: AppPaths.recordings.appendingPathComponent(name))
                store.update(entry.id) { $0.localFileName = nil }
            }
            try? FileManager.default.removeItem(at: AppPaths.downloadURL(for: entry.id))
        }
        storageTick += 1
        model.showToast("Local copies removed. Entries stay in Google Drive.")
    }
}

private struct RecordingSettings: View {
    @EnvironmentObject private var camera: CameraController
    @AppStorage(Prefs.countdown) private var countdown = true
    @AppStorage(Prefs.prompts) private var prompts = true
    @AppStorage(Prefs.mirror) private var mirror = true
    @AppStorage(Prefs.hevc) private var hevc = true

    var body: some View {
        Form {
            Section("Devices") {
                Picker("Camera", selection: Binding(
                    get: { camera.activeVideoID ?? UserDefaults.standard.string(forKey: Prefs.videoDevice) ?? AVCaptureDevice.default(for: .video)?.uniqueID ?? "" },
                    set: { id in if let d = camera.videoDevices.first(where: { $0.uniqueID == id }) { camera.selectDevice(d, for: .video) } }
                )) {
                    ForEach(camera.videoDevices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                Picker("Microphone", selection: Binding(
                    get: { camera.activeAudioID ?? UserDefaults.standard.string(forKey: Prefs.audioDevice) ?? AVCaptureDevice.default(for: .audio)?.uniqueID ?? "" },
                    set: { id in if let d = camera.audioDevices.first(where: { $0.uniqueID == id }) { camera.selectDevice(d, for: .audio) } }
                )) {
                    ForEach(camera.audioDevices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            Section("Recording") {
                Toggle("3-second countdown before recording", isOn: $countdown)
                Toggle("Show a journaling prompt", isOn: $prompts)
                Toggle("Mirror the preview (like a mirror)", isOn: $mirror)
                Toggle("Smaller files (HEVC)", isOn: $hevc)
                    .help("HEVC files are about half the size of H.264 at the same quality.")
            }
        }
        .formStyle(.grouped)
        .onAppear { camera.refreshDevices() }
    }
}

private struct ReminderSettings: View {
    @AppStorage(Prefs.reminderEnabled) private var enabled = false
    @AppStorage(Prefs.reminderMinutes) private var minutes = 21 * 60

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes = (c.hour ?? 21) * 60 + (c.minute ?? 0)
                Reminders.refresh()
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Daily reminder", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        Task {
                            if on { _ = await Reminders.requestPermission() }
                            Reminders.refresh()
                        }
                    }
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    .disabled(!enabled)
            } footer: {
                Text("A gentle notification to keep your streak going.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
