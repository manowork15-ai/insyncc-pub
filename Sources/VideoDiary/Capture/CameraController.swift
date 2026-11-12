import AppKit
import AVFoundation
import SwiftUI

/// Owns the capture session: live preview, device selection, mic level metering and recording.
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

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "VideoDiary.camera")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var configured = false
    private var meterTimer: Timer?
    private var completion: ((Result<URL, Error>) -> Void)?

    override init() {
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
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices.filter { $0.deviceType != .deskViewCamera }
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
        guard configured else { return }
        queue.async { [self] in
            session.beginConfiguration()
            if type == .video {
                if let old = videoInput { session.removeInput(old) }
                videoInput = addInput(device)
            } else {
                if let old = audioInput { session.removeInput(old) }
                audioInput = addInput(device)
            }
            session.commitConfiguration()
            applyCodec()
            publishActiveDevices()
        }
    }

    // MARK: Session lifecycle

    func start() {
        guard cameraAccess == .authorized else { return }
        queue.async { [self] in
            configureIfNeeded()
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async {
                self.isRunning = self.session.isRunning
                self.startMeter()
            }
        }
    }

    /// Turns the camera (and its green light) off. Ignored while recording.
    func stop() {
        guard !isRecording else { return }
        stopMeter()
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        if let device = preferredDevice(for: .video) { videoInput = addInput(device) }
        if micAccess == .authorized, let device = preferredDevice(for: .audio) { audioInput = addInput(device) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        movieOutput.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 1) // crash-safe files
        session.commitConfiguration()
        applyCodec()
        configured = true
        publishActiveDevices()
        if videoInput == nil {
            DispatchQueue.main.async { self.lastError = "No camera found." }
        }
    }

    private func addInput(_ device: AVCaptureDevice) -> AVCaptureDeviceInput? {
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        return input
    }

    private func applyCodec() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        let wantHEVC = UserDefaults.standard.bool(forKey: Prefs.hevc)
        let codec: AVVideoCodecType = wantHEVC && movieOutput.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
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

    // MARK: Metering

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let channel = self.movieOutput.connection(with: .audio)?.audioChannels.first {
                // Map -50 dB...0 dB onto 0...1 with a little smoothing.
                let db = max(-50, min(0, channel.averagePowerLevel))
                let level = (db + 50) / 50
                self.audioLevel = self.audioLevel * 0.5 + level * 0.5
            } else {
                self.audioLevel = 0
            }
            if self.isRecording {
                let seconds = self.movieOutput.recordedDuration.seconds
                if seconds.isFinite { self.elapsed = seconds }
            }
        }
    }

    private func stopMeter() {
        meterTimer?.invalidate()
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

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool
    /// Passed in so SwiftUI re-runs `updateNSView` once the connection exists.
    var isRunning: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.mirrored = mirrored
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.mirrored = mirrored
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var mirrored = true { didSet { applyMirroring() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
            applyMirroring()
        }

        private func applyMirroring() {
            guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }
}
