import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import AppKit

// MARK: - RecordingSession (disposable — one per recording, fully isolated)

private final class RecordingSession: NSObject, @unchecked Sendable,
    SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
{
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let stream: SCStream
    let micSession: AVCaptureSession?

    private let videoQueue = DispatchQueue(label: "com.loom.vid.\(UUID())", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.loom.aud.\(UUID())", qos: .userInitiated)

    private let lock = NSLock()
    private var sessionStarted = false
    private var paused = false
    private var stopped = false
    private var firstSampleTime: CMTime = .invalid
    private var lastSampleBuffer: CMSampleBuffer?

    init(display: SCDisplay, mic: AVCaptureDevice?, outputURL: URL) throws {
        // -- Writer --
        let w = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 1)
        self.writer = w

        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        let vidW = display.width * scale
        let vidH = display.height * scale

        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: vidW,
            AVVideoHeightKey: vidH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        vi.expectsMediaDataInRealTime = true
        w.add(vi)
        self.videoInput = vi

        // -- Mic session (set up BEFORE writer audio input to detect format) --
        var micSess: AVCaptureSession? = nil
        var ai: AVAssetWriterInput? = nil

        if let mic {
            let session = AVCaptureSession()
            let devInput = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(devInput) { session.addInput(devInput) }

            let output = AVCaptureAudioDataOutput()
            if session.canAddOutput(output) { session.addOutput(output) }

            let recommended = output.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
            let audioSettings = recommended ?? [AVFormatIDKey: kAudioFormatMPEG4AAC]

            let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioWriterInput.expectsMediaDataInRealTime = true
            w.add(audioWriterInput)
            ai = audioWriterInput
            micSess = session

            print("[FreeLum] Mic: \(mic.localizedName) settings: \(audioSettings)")
        }
        self.audioInput = ai
        self.micSession = micSess

        // -- SCStream --
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = vidW
        config.height = vidH
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        self.stream = SCStream(filter: filter, configuration: config, delegate: nil)

        super.init()

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)

        if let output = micSess?.outputs.first as? AVCaptureAudioDataOutput {
            output.setSampleBufferDelegate(self, queue: audioQueue)
        }
    }

    func start() async throws {
        try await stream.startCapture()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.micSession?.startRunning()
        }
        print("[FreeLum] Capture started")
    }

    func setPaused(_ p: Bool) {
        lock.lock()
        paused = p
        lock.unlock()
    }

    func stop() async {
        // 1. Stop sources first so no new callbacks fire
        try? await stream.stopCapture()
        micSession?.stopRunning()

        // 2. Mark as stopped and grab last buffer
        lock.lock()
        stopped = true
        let lastBuf = lastSampleBuffer
        lastSampleBuffer = nil
        let started = sessionStarted
        lock.unlock()

        // 3. Drain queues — any in-flight callbacks see stopped=true and skip
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            videoQueue.async { self.audioQueue.async { c.resume() } }
        }

        // 4. Append a final copy of the last frame at current time
        //    (SCStream only sends frames on screen change, so the last
        //     frame's timestamp can be far earlier than stop time)
        if started, let lastBuf, writer.status == .writing {
            let now = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 100)
            let endPTS = CMTimeSubtract(now, firstSampleTime)
            if endPTS > .zero {
                let timing = CMSampleTimingInfo(
                    duration: lastBuf.duration,
                    presentationTimeStamp: endPTS,
                    decodeTimeStamp: .invalid
                )
                if let finalBuf = try? CMSampleBuffer(copying: lastBuf, withNewTiming: [timing]),
                   videoInput.isReadyForMoreMediaData {
                    videoInput.append(finalBuf)
                }
            }
        }

        // 5. Finalize
        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        if writer.status == .writing {
            await writer.finishWriting()
            print("[FreeLum] Writer finished OK, status: \(writer.status.rawValue)")
        } else {
            print("[FreeLum] Writer status at stop: \(writer.status.rawValue) error: \(writer.error?.localizedDescription ?? "none")")
        }
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sb.isValid else { return }

        // Only process complete frames — idle/blank/suspended frames
        // carry no valid pixel data and would cause the writer to fail
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete
        else { return }

        writeVideo(sb)
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        writeAudio(sb)
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("[FreeLum] Stream error: \(error.localizedDescription)")
    }

    // MARK: - Writing

    private func writeVideo(_ sb: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !paused else { return }
        guard writer.status != .failed else { return }

        if !sessionStarted {
            guard writer.startWriting() else {
                print("[FreeLum] startWriting FAILED: \(writer.error?.localizedDescription ?? "?")")
                return
            }
            firstSampleTime = sb.presentationTimeStamp
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
            print("[FreeLum] Session started at \(sb.presentationTimeStamp.seconds)s")
        }

        // Retime relative to first frame so the video starts at 0
        let adjusted = CMTimeSubtract(sb.presentationTimeStamp, firstSampleTime)
        guard let retimed = try? CMSampleBuffer(copying: sb, withNewTiming: [
            CMSampleTimingInfo(duration: sb.duration, presentationTimeStamp: adjusted, decodeTimeStamp: .invalid)
        ]) else { return }

        lastSampleBuffer = retimed

        if videoInput.isReadyForMoreMediaData {
            if !videoInput.append(retimed) {
                print("[FreeLum] VIDEO APPEND FAIL: \(writer.error?.localizedDescription ?? "?")")
            }
        }
    }

    private func writeAudio(_ sb: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !paused, sessionStarted else { return }
        guard writer.status == .writing else { return }
        guard let audioInput else { return }

        // Retime audio relative to first video frame
        let adjusted = CMTimeSubtract(sb.presentationTimeStamp, firstSampleTime)
        guard adjusted.seconds >= 0 else { return }

        guard let retimed = try? CMSampleBuffer(copying: sb, withNewTiming: [
            CMSampleTimingInfo(duration: sb.duration, presentationTimeStamp: adjusted, decodeTimeStamp: .invalid)
        ]) else { return }

        if audioInput.isReadyForMoreMediaData {
            if !audioInput.append(retimed) {
                print("[FreeLum] AUDIO APPEND FAIL: \(writer.error?.localizedDescription ?? "?")")
            }
        }
    }
}

// MARK: - ScreenRecorder (public interface)

@Observable
final class ScreenRecorder: @unchecked Sendable {

    var isRecording = false
    var isPaused = false
    var duration: TimeInterval = 0
    var availableDisplays: [SCDisplay] = []
    var availableMicrophones: [AVCaptureDevice] = []
    var selectedDisplay: SCDisplay?
    var selectedMicrophone: AVCaptureDevice?
    var errorMessage: String?
    var savedURL: URL?

    // Completely isolated session — created fresh, destroyed fully
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startDate: Date?
    @ObservationIgnored private var pausedTotal: TimeInterval = 0
    @ObservationIgnored private var pauseDate: Date?

    func loadAvailableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableDisplays = content.displays
            if selectedDisplay == nil { selectedDisplay = content.displays.first }
        } catch {
            errorMessage = "Screen recording permission required.\nSystem Settings → Privacy & Security → Screen Recording."
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        )
        availableMicrophones = discovery.devices
        if selectedMicrophone == nil { selectedMicrophone = AVCaptureDevice.default(for: .audio) }
    }

    func startRecording() async {
        // Destroy any previous session completely
        if let old = session {
            await old.stop()
            session = nil
        }

        await loadAvailableContent()

        guard let display = selectedDisplay else {
            errorMessage = "No display selected"
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let fileName = "FreeLum-\(formatter.string(from: Date())).mov"
        let loomDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeLum Recordings")
        try? FileManager.default.createDirectory(at: loomDir, withIntermediateDirectories: true)
        let outputURL = loomDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: outputURL)

        do {
            let s = try RecordingSession(display: display, mic: selectedMicrophone, outputURL: outputURL)
            session = s
            savedURL = outputURL

            try await s.start()

            isRecording = true
            isPaused = false
            duration = 0
            pausedTotal = 0
            startDate = Date()
            errorMessage = nil

            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, self.isRecording, !self.isPaused else { return }
                self.duration = Date().timeIntervalSince(self.startDate ?? Date()) - self.pausedTotal
            }
        } catch {
            errorMessage = "Failed to start: \(error.localizedDescription)"
            session = nil
        }
    }

    func togglePause() {
        if isPaused {
            if let pd = pauseDate { pausedTotal += Date().timeIntervalSince(pd) }
            session?.setPaused(false)
            isPaused = false
            pauseDate = nil
        } else {
            session?.setPaused(true)
            isPaused = true
            pauseDate = Date()
        }
    }

    func stopRecording() async {
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false

        if let s = session {
            await s.stop()
            session = nil  // fully release
        }

        if let url = savedURL {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        }
        duration = 0
    }
}
