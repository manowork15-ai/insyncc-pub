import AppKit
import AVFoundation
import SwiftUI

/// Owns the capture session: live preview, device selection, mic level metering and recording.
///
/// Threading rule: the main thread never touches `session`, its inputs/outputs or the preview
/// layer's connection. AVFoundation's `stopRunning()` synchronously hops to the main thread
/// (movie file output teardown), so any session-lock acquisition on main — e.g. a preview layer
/// being deallocated, which detaches it from the session — deadlocks the app. All session work
/// happens on `queue`, metering on `meterQueue`, and the single preview layer lives as long as
/// the controller so it is never deallocated mid-teardown.
final class CameraController: NSObject, ObservableObject {
    @Published private(set) var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var micAccess = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var videoDevices: [AVCaptureDevice] = []
    @Published private(set) var audioDevices: [AVCaptureDevice] = []
    @Published private(set) var activeVideoID: String?
    @Published private(set) var activeAudioID: String?
    @Published var lastError: String?

    /// One long-lived preview layer, re-parented into whichever view is showing the camera.
    let previewLayer: AVCaptureVideoPreviewLayer

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "VideoDiary.camera")
    private let meterQueue = DispatchQueue(label: "VideoDiary.camera.meter")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var configured = false
    private var meterTimer: DispatchSourceTimer?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var mirrored = true

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        super.init()
        refreshDevices()
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDevices()
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    // MARK: Permissions & devices

    @MainActor
    func requestAccess() async {
        if cameraAccess == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
        if micAccess == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        micAccess = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func refreshDevices() {
        videoDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
        audioDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }

    private func preferredDevice(for type: AVMediaType) -> AVCaptureDevice? {
        let key = type == .video ? Prefs.videoDevice : Prefs.audioDevice
        if let id = UserDefaults.standard.string(forKey: key), let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(for: type)
    }

    func selectDevice(_ device: AVCaptureDevice, for type: AVMediaType) {
        UserDefaults.standard.set(device.uniqueID, forKey: type == .video ? Prefs.videoDevice : Prefs.audioDevice)
        queue.async { [self] in
            guard configured, !movieOutput.isRecording else { return }
            session.beginConfiguration()
            if type == .video {
                if let old = videoInput { session.removeInput(old) }
                videoInput = addInput(device)
                connectPreview()
            } else {
                if let old = audioInput { session.removeInput(old) }
                audioInput = addInput(device)
            }
            session.commitConfiguration()
            applyCodec()
            applyMirroring()
            publishActiveDevices()
        }
    }

    // MARK: Session lifecycle

    func start() {
        guard cameraAccess == .authorized else { return }
        queue.async { [self] in
            configureIfNeeded()
            if !session.isRunning { session.startRunning() }
            applyMirroring()
            let running = session.isRunning
            DispatchQueue.main.async {
                self.isRunning = running
                self.startMeter()
            }
        }
    }

    /// Turns the camera (and its green light) off. Ignored while recording.
    func stop() {
        stopMeter()
        queue.async { [self] in
            guard !movieOutput.isRecording, session.isRunning else { return }
            session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func setMirrored(_ value: Bool) {
        queue.async { [self] in
            mirrored = value
            applyMirroring()
        }
    }

    // Must run on `queue`.
    private func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    // Must run on `queue`.
    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        if let device = preferredDevice(for: .video) { videoInput = addInput(device) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let device = preferredDevice(for: .audio) {
            audioInput = addInput(device)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        movieOutput.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 1) // crash-safe files
        connectPreview()
        session.commitConfiguration()
        applyCodec()
        configured = true
        publishActiveDevices()
        if videoInput == nil {
            DispatchQueue.main.async { self.lastError = "No camera found." }
        }
    }

    /// The preview layer was created without a connection so its wiring happens here, on `queue`.
    private func connectPreview() {
        // Removing the previous input already removed its preview connection.
        guard let port = videoInput?.ports.first(where: { $0.mediaType == .video }) else { return }
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
        if session.canAddConnection(connection) { session.addConnection(connection) }
    }

    private func addInput(_ device: AVCaptureDevice) -> AVCaptureDeviceInput? {
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        return input
    }

    private func applyCodec() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        // Every Mac that runs macOS 14 can encode HEVC in hardware.
        let codec: AVVideoCodecType = UserDefaults.standard.bool(forKey: Prefs.hevc) ? .hevc : .h264
        movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: connection)
    }

    private func publishActiveDevices() {
        let v = videoInput?.device.uniqueID, a = audioInput?.device.uniqueID
        DispatchQueue.main.async {
            self.activeVideoID = v
            self.activeAudioID = a
        }
    }

    // MARK: Recording

    func startRecording(to url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isRecording else { return }
        self.completion = completion
        isRecording = true
        elapsed = 0
        queue.async { [self] in
            applyCodec()
            movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        queue.async { [self] in
            if movieOutput.isRecording { movieOutput.stopRecording() }
        }
    }

    // MARK: Metering (off the main thread)

    private func startMeter() {
        stopMeter()
        let timer = DispatchSource.makeTimerSource(queue: meterQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        var smoothed: Float = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let channel = self.movieOutput.connection(with: .audio)?.audioChannels.first {
                // Map -50 dB...0 dB onto 0...1 with a little smoothing.
                let db = max(-50, min(0, channel.averagePowerLevel))
                smoothed = smoothed * 0.5 + ((db + 50) / 50) * 0.5
            } else {
                smoothed = 0
            }
            let recording = self.movieOutput.isRecording
            let seconds = recording ? self.movieOutput.recordedDuration.seconds : 0
            let level = smoothed
            DispatchQueue.main.async {
                self.audioLevel = level
                if recording, seconds.isFinite { self.elapsed = seconds }
            }
        }
        meterTimer = timer
        timer.resume()
    }

    private func stopMeter() {
        meterTimer?.cancel()
        meterTimer = nil
        audioLevel = 0
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        var succeeded = true
        if let error = error as NSError? {
            succeeded = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
        }
        DispatchQueue.main.async {
            self.isRecording = false
            let done = self.completion
            self.completion = nil
            if succeeded {
                done?(.success(outputFileURL))
            } else {
                self.lastError = error?.localizedDescription
                done?(.failure(error ?? CocoaError(.fileWriteUnknown)))
            }
        }
    }
}

// MARK: - Preview

/// Hosts the controller's shared preview layer. Views come and go; the layer does not,
/// so tearing down a view never touches the capture session.
struct CameraPreview: NSViewRepresentable {
    let camera: CameraController
    var mirrored: Bool

    func makeNSView(context: Context) -> HostView {
        let view = HostView(previewLayer: camera.previewLayer)
        camera.setMirrored(mirrored)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.claim()
        if context.coordinator.mirrored != mirrored {
            context.coordinator.mirrored = mirrored
            camera.setMirrored(mirrored)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(mirrored: mirrored) }

    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        view.release()
    }

    final class Coordinator {
        var mirrored: Bool
        init(mirrored: Bool) { self.mirrored = mirrored }
    }

    final class HostView: NSView {
        private let previewLayer: AVCaptureVideoPreviewLayer

        init(previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            super.init(frame: .zero)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            claim()
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Moves the shared layer into this view (plain CALayer re-parenting; no session access).
        func claim() {
            guard let host = layer, previewLayer.superlayer !== host else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.removeFromSuperlayer()
            host.addSublayer(previewLayer)
            previewLayer.frame = bounds
            CATransaction.commit()
        }

        func release() {
            guard previewLayer.superlayer === layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.removeFromSuperlayer()
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            guard previewLayer.superlayer === layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
