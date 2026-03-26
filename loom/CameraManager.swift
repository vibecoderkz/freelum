import AVFoundation
import AppKit

@Observable
final class CameraManager: @unchecked Sendable {

    var availableCameras: [AVCaptureDevice] = []
    var selectedCamera: AVCaptureDevice?
    var isCameraEnabled = true

    @ObservationIgnored
    nonisolated(unsafe) let captureSession = AVCaptureSession()

    @ObservationIgnored
    nonisolated(unsafe) private var currentInput: AVCaptureDeviceInput?

    @ObservationIgnored
    nonisolated(unsafe) private var isRunning = false

    func loadCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discovery.devices
        if selectedCamera == nil {
            selectedCamera = AVCaptureDevice.default(for: .video)
        }
    }

    func startPreview() {
        guard isCameraEnabled, let camera = selectedCamera else { return }

        captureSession.beginConfiguration()

        if let currentInput {
            captureSession.removeInput(currentInput)
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                currentInput = input
            }
        } catch {
            print("Camera setup error: \(error)")
        }

        captureSession.commitConfiguration()

        if !isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                captureSession.startRunning()
            }
            isRunning = true
        }
    }

    func stopPreview() {
        guard isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            captureSession.stopRunning()
        }
        isRunning = false
    }

    func selectCamera(_ camera: AVCaptureDevice) {
        selectedCamera = camera
        if isRunning {
            startPreview()
        }
    }
}
