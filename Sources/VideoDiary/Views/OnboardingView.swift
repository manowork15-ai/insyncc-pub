import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: GoogleAuth
    @EnvironmentObject private var camera: CameraController

    enum Step: Int, CaseIterable { case welcome, google, folder, camera }
    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome: WelcomeStep { advance() }
                case .google: GoogleStep(next: advance, skip: { step = .camera })
                case .folder: FolderStep(next: advance)
                case .camera: CameraStep { model.finishOnboarding() }
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: s == step ? 22 : 8, height: 8)
                }
            }
            .padding(.bottom, 28)
        }
        .animation(.spring(duration: 0.4), value: step)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func advance() {
        var next = Step(rawValue: step.rawValue + 1) ?? .camera
        // Already have a folder from a previous setup? Skip that step.
        if next == .folder, Prefs.rootFolder != nil { next = .camera }
        step = next
    }
}

private struct StepHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
                .frame(height: 56)
            Text(title).font(.largeTitle.bold())
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 110, height: 110)
                Image(systemName: "video.fill").font(.system(size: 46)).foregroundStyle(.white)
            }
            .shadow(color: .red.opacity(0.3), radius: 20, y: 8)

            VStack(spacing: 10) {
                Text("Video Diary").font(.system(size: 40, weight: .bold))
                Text("Talk to your future self. Open the app, hit record, and every entry is neatly filed in your own Google Drive.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                feature("record.circle", "One click (or Space) to record")
                feature("tag", "Title, mood and tags in seconds")
                feature("folder", "Organised by year and month in Drive")
                feature("lock", "Private: stored only in your Google account")
            }

            Button(action: next) {
                Text("Get Started").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 24)
        }
        .font(.body)
    }
}

private struct GoogleStep: View {
    @EnvironmentObject private var auth: GoogleAuth
    @EnvironmentObject private var model: AppModel
    let next: () -> Void
    let skip: () -> Void

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var error: String?
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 28) {
            StepHeader(icon: "externaldrive.badge.icloud", title: "Connect Google Drive",
                       subtitle: "Entries are uploaded to a folder you choose in your Drive.")

            if auth.isSignedIn {
                VStack(spacing: 8) {
                    Label("Connected", systemImage: "checkmark.circle.fill").font(.title3.bold()).foregroundStyle(.green)
                    if let email = auth.accountEmail { Text(email).foregroundStyle(.secondary) }
                }
                Button("Continue", action: next)
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            } else {
                if !auth.hasBundledCredentials {
                    CredentialsForm(clientID: $clientID, clientSecret: $clientSecret, showHelp: $showHelp)
                }

                if let error {
                    Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
                }

                if auth.isSigningIn {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                        Button("Cancel") { auth.cancelSignIn() }
                    }
                } else {
                    VStack(spacing: 12) {
                        Button {
                            signIn()
                        } label: {
                            Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                                .frame(minWidth: 200)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!auth.hasBundledCredentials && clientID.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button("Set up later. Keep entries on this Mac for now.", action: skip)
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .onAppear {
            clientID = auth.credentials?.clientID ?? ""
            clientSecret = auth.credentials?.clientSecret ?? ""
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
                next()
            } catch is CancellationError {
                // user cancelled
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct CredentialsForm: View {
    @Binding var clientID: String
    @Binding var clientSecret: String
    @Binding var showHelp: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("OAuth Client ID (…apps.googleusercontent.com)", text: $clientID)
                .textFieldStyle(.roundedBorder)
            SecureField("Client secret", text: $clientSecret)
                .textFieldStyle(.roundedBorder)
            DisclosureGroup("Where do I get these?", isExpanded: $showHelp) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This is a one-time setup so the app talks to Drive under your own Google project:")
                    Text("1. In Google Cloud Console, create a project and enable the **Google Drive API**.")
                    Text("2. Under **Google Auth Platform**, configure the consent screen (External) and add yourself as a test user, or publish it.")
                    Text("3. Under **Clients**, create an OAuth client of type **Desktop app**.")
                    Text("4. Paste the client ID and secret here.")
                    Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                        .padding(.top, 4)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
            .font(.callout)
        }
        .frame(maxWidth: 440)
    }
}

private struct FolderStep: View {
    @EnvironmentObject private var model: AppModel
    let next: () -> Void
    @State private var creating = false
    @State private var browsing = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(icon: "folder.badge.gearshape", title: "Where should entries go?",
                       subtitle: "Pick a Google Drive folder. Entries are filed into year and month subfolders automatically.")

            Text(DiaryLayout.examplePath(root: "Video Diary"))
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .textSelection(.enabled)

            if browsing {
                FolderPickerView(drive: model.drive) { id, name in choose(id, name) }
                    .frame(height: 300)
            } else {
                VStack(spacing: 12) {
                    Button {
                        createDefault()
                    } label: {
                        if creating {
                            ProgressView().controlSize(.small).frame(minWidth: 260)
                        } else {
                            Label("Create “Video Diary” in My Drive", systemImage: "folder.badge.plus").frame(minWidth: 260)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating)

                    Button("Choose an existing folder…") { browsing = true }
                        .controlSize(.large)
                }
            }

            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
    }

    private func createDefault() {
        creating = true
        Task {
            defer { creating = false }
            do {
                let id = try await model.drive.findOrCreateFolder(named: "Video Diary", in: "root")
                choose(id, "Video Diary")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func choose(_ id: String, _ name: String) {
        Prefs.setRootFolder(id: id, name: name)
        model.sync.resetFolderCache()
        next()
    }
}

private struct CameraStep: View {
    @EnvironmentObject private var camera: CameraController
    @AppStorage(Prefs.mirror) private var mirror = true
    @AppStorage(Prefs.reminderEnabled) private var reminder = false
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(icon: "camera", title: "Say hello",
                       subtitle: "Allow camera and microphone access so you can record.")

            ZStack {
                if camera.cameraAccess == .authorized {
                    CameraPreview(camera: camera, mirrored: mirror)
                } else {
                    Color.black.opacity(0.85)
                    if camera.cameraAccess == .denied {
                        Text("Camera access is off. Enable it in System Settings › Privacy & Security › Camera.")
                            .foregroundStyle(.white).multilineTextAlignment(.center).padding()
                    }
                }
            }
            .frame(width: 400, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if camera.isRunning { AudioMeter(level: camera.audioLevel).padding(12) }
            }

            Toggle("Remind me every evening to record", isOn: $reminder)
                .onChange(of: reminder) { _, on in
                    Task {
                        if on { _ = await Reminders.requestPermission() }
                        Reminders.refresh()
                    }
                }

            if camera.cameraAccess == .notDetermined {
                Button("Allow Camera & Microphone") {
                    Task { await camera.requestAccess(); camera.start() }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            } else {
                Button {
                    camera.stop()
                    finish()
                } label: {
                    Text("Start My First Entry").frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { camera.start() }
    }
}
