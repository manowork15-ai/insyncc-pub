import AVFoundation
import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var camera: CameraController

    var body: some View {
        Group {
            if case .review(let take) = model.recordPhase {
                ReviewView(take: take)
                    .transition(.opacity)
            } else if camera.cameraAccess == .denied || camera.cameraAccess == .restricted {
                PermissionDeniedView()
            } else {
                CaptureView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.recordPhase)
        .navigationTitle("New Entry")
    }
}

// MARK: - Capture

private struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var camera: CameraController
    @AppStorage(Prefs.countdown) private var countdownEnabled = true
    @AppStorage(Prefs.prompts) private var showPrompts = true
    @AppStorage(Prefs.mirror) private var mirror = true
    @State private var prompt = JournalPrompts.random()
    @State private var countdownTask: Task<Void, Never>?
    @State private var blink = false

    private var phase: RecordPhase { model.recordPhase }
    private var isRecording: Bool { if case .recording = phase { return true } else { return false } }
    private var countdownValue: Int? { if case .countdown(let n) = phase { return n } else { return nil } }

    var body: some View {
        ZStack {
            CameraPreview(camera: camera, mirrored: mirror)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    if !camera.isRunning {
                        ProgressView().controlSize(.large).tint(.white)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(isRecording ? Color.red.opacity(0.9) : .clear, lineWidth: 4)
                        .animation(.easeInOut, value: isRecording)
                )

            // Top: date + prompt
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.headline)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if isRecording {
                        HStack(spacing: 8) {
                            Circle().fill(.red).frame(width: 10, height: 10).opacity(blink ? 0.25 : 1)
                            Text(camera.elapsed.clockString).font(.system(.headline, design: .monospaced))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { blink = true }
                        }
                        .onDisappear { blink = false }
                    }
                }

                if showPrompts && !isRecording && countdownValue == nil {
                    PromptCard(prompt: prompt) { prompt = JournalPrompts.random(excluding: prompt) }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(20)
            .foregroundStyle(.white)

            if let n = countdownValue {
                Text("\(n)")
                    .font(.system(size: 160, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 20)
                    .contentTransition(.numericText(countsDown: true))
                    .id(n)
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
            }

            // Bottom controls
            VStack {
                Spacer()
                HStack(alignment: .center) {
                    AudioMeter(level: camera.audioLevel)
                        .frame(width: 120, alignment: .leading)
                        .opacity(camera.micAccess == .authorized ? 1 : 0)
                    Spacer()
                    RecordButton(isRecording: isRecording, action: toggle)
                    Spacer()
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 120, alignment: .trailing)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                )
            }

            if camera.micAccess == .denied {
                VStack {
                    Spacer()
                    Label("Microphone access is off. Entries will be silent.", systemImage: "mic.slash.fill")
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 110)
                }
                .foregroundStyle(.white)
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.spring(duration: 0.35), value: countdownValue)
        .animation(.easeInOut(duration: 0.25), value: isRecording)
        .onAppear(perform: activate)
        .onDisappear(perform: deactivate)
        .onExitCommand(perform: cancelCountdown)
        .alert("Recording problem", isPresented: Binding(get: { camera.lastError != nil }, set: { if !$0 { camera.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.lastError ?? "")
        }
    }

    private var hint: String {
        if isRecording { return "Space to finish" }
        if countdownValue != nil { return "Space to skip · Esc to cancel" }
        return "Press Space to start"
    }

    private func activate() {
        Task {
            await camera.requestAccess()
            camera.start()
        }
    }

    private func deactivate() {
        cancelCountdown()
        if isRecording { camera.stopRecording() } else { camera.stop() }
    }

    private func toggle() {
        switch phase {
        case .idle:
            if countdownEnabled { runCountdown() } else { beginRecording() }
        case .countdown:
            beginRecording()
        case .recording:
            camera.stopRecording()
        case .review:
            break
        }
    }

    private func runCountdown() {
        countdownTask?.cancel()
        model.recordPhase = .countdown(3)
        countdownTask = Task { @MainActor in
            for n in [2, 1] {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled, case .countdown = model.recordPhase else { return }
                model.recordPhase = .countdown(n)
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, case .countdown = model.recordPhase else { return }
            beginRecording()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        if case .countdown = model.recordPhase { model.recordPhase = .idle }
    }

    private func beginRecording() {
        countdownTask?.cancel()
        guard camera.isRunning else { model.recordPhase = .idle; return }
        let model = self.model, camera = self.camera // outlive this view if you navigate away
        let (id, url) = model.newTakeURL()
        let started = Date()
        model.recordPhase = .recording(startedAt: started)
        camera.startRecording(to: url) { result in
            switch result {
            case .success(let file):
                let fallback = camera.elapsed
                Task { @MainActor in
                    let measured = await MediaTools.duration(of: file)
                    _ = await MediaTools.makeThumbnail(for: file, id: id)
                    model.recordPhase = .review(Take(id: id, url: file, startedAt: started,
                                                     duration: measured > 0 ? measured : fallback))
                    camera.stop() // camera light off while reviewing
                }
            case .failure:
                try? FileManager.default.removeItem(at: url)
                model.recordPhase = .idle
            }
        }
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 30, style: .continuous)
                    .fill(.red)
                    .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
                    .scaleEffect(hovering ? 1.05 : 1)
            }
            .contentShape(Circle())
            .animation(.spring(duration: 0.3), value: isRecording)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .onHover { hovering = $0 }
        .help(isRecording ? "Stop recording (Space)" : "Start recording (Space)")
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

private struct PromptCard: View {
    let prompt: String
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            Text(prompt).font(.title3.weight(.medium)).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Button(action: shuffle) {
                Image(systemName: "shuffle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white)
            .help("Another prompt")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

private struct PermissionDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Camera access is off", systemImage: "video.slash")
        } description: {
            Text("Video Diary needs your camera to record entries. Turn it on in System Settings › Privacy & Security › Camera, then reopen the app.")
        } actions: {
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Review

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: EntryStore
    let take: Take
    @State private var draft = EntryDraft()
    @State private var confirmDiscard = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                PlayerView(url: take.url)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack {
                    Label(take.duration.clockString, systemImage: "clock")
                    Text("·")
                    Text(take.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(AppPaths.size(of: take.url).byteString)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Save this entry").font(.title2.bold())
                        MetadataForm(draft: $draft,
                                     titlePlaceholder: DiaryLayout.suggestedTitle(for: take.startedAt),
                                     suggestedTags: store.popularTags,
                                     focusTitle: true)
                        if let root = Prefs.rootFolder {
                            Label {
                                Text(([root.name] + DiaryLayout.folderPath(for: take.startedAt)).joined(separator: " › "))
                            } icon: {
                                Image(systemName: "folder")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                }

                Divider()

                HStack {
                    Button("Retake", role: .destructive) { confirmDiscard = true }
                        .keyboardShortcut(.delete, modifiers: .command)
                    Spacer()
                    Button {
                        model.save(take, draft: draft)
                    } label: {
                        Text("Save Entry").frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Save (⌘↩)")
                }
                .padding(16)
            }
            .frame(width: 360)
        }
        .confirmationDialog("Discard this take and record again?", isPresented: $confirmDiscard) {
            Button("Discard & Retake", role: .destructive) { model.discard(take) }
            Button("Keep Reviewing", role: .cancel) {}
        }
    }
}

enum JournalPrompts {
    static let all = [
        "What was the best part of today?",
        "What's on your mind right now?",
        "What are you grateful for today?",
        "What surprised you today?",
        "What did you learn today?",
        "What's something that challenged you?",
        "Who made your day better?",
        "What are you looking forward to?",
        "How are you really feeling?",
        "What would you tell yourself a year ago?",
        "What's one thing you'd do differently today?",
        "What made you laugh recently?",
        "What are you worried about, and what can you control?",
        "Describe where you are right now.",
        "What's a small win worth celebrating?",
        "What do you want to remember about this week?",
        "What drained your energy today? What gave you energy?",
        "What are you proud of lately?",
    ]

    static func random(excluding current: String? = nil) -> String {
        all.filter { $0 != current }.randomElement() ?? all[0]
    }
}
