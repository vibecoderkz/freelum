import SwiftUI
import AVFoundation
import ScreenCaptureKit

// MARK: - Camera Shape

enum CameraShape: String, CaseIterable {
    case circle, rounded, pill
}

// MARK: - Screen Corner

enum ScreenCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var icon: String {
        switch self {
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @State private var recorder = ScreenRecorder()
    @State private var cameraManager = CameraManager()
    @State private var cameraPanel: NSPanel?
    @State private var pulseAnimation = false

    @State private var selectedDisplayID: CGDirectDisplayID = 0
    @State private var selectedCameraID: String = ""
    @State private var selectedMicID: String = ""

    @State private var cameraShape: CameraShape = .circle
    @State private var zoomOnClick = true

    @State private var countdownValue: Int = 0
    @State private var countdownWindow: NSWindow?
    @State private var countdownTask: Task<Void, Never>?

    @State private var globalMonitor: Any?
    @State private var localMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            if countdownValue > 0 {
                countdownView
                    .padding(20)
            } else if recorder.isRecording {
                recordingView
                    .padding(14)
            } else {
                setupView
                    .padding(14)
            }

            if let error = recorder.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Text("Quit FreeLum")
                    Spacer()
                    Text("\u{2318}Q")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
        .background(.regularMaterial)
        .task {
            await recorder.loadAvailableContent()
            cameraManager.loadCameras()
            selectedDisplayID = recorder.selectedDisplay?.displayID ?? 0
            selectedCameraID = cameraManager.selectedCamera?.uniqueID ?? ""
            selectedMicID = recorder.selectedMicrophone?.uniqueID ?? ""
        }
        .onAppear { registerHotkeys() }
        .onDisappear { unregisterHotkeys() }
        .onChange(of: selectedDisplayID) { _, newID in
            recorder.selectedDisplay = recorder.availableDisplays.first { $0.displayID == newID }
        }
        .onChange(of: selectedCameraID) { _, newID in
            if newID.isEmpty { cameraManager.selectedCamera = nil }
            else { cameraManager.selectedCamera = cameraManager.availableCameras.first { $0.uniqueID == newID } }
        }
        .onChange(of: selectedMicID) { _, newID in
            if newID.isEmpty { recorder.selectedMicrophone = nil }
            else { recorder.selectedMicrophone = recorder.availableMicrophones.first { $0.uniqueID == newID } }
        }
        .onChange(of: recorder.isRecording) { _, recording in
            if recording && cameraManager.isCameraEnabled {
                cameraManager.startPreview(); showCameraPanel()
            } else if !recording {
                cameraManager.stopPreview(); hideCameraPanel()
            }
        }
        .onChange(of: cameraManager.isCameraEnabled) { _, enabled in
            if recorder.isRecording {
                if enabled { cameraManager.startPreview(); showCameraPanel() }
                else { cameraManager.stopPreview(); hideCameraPanel() }
            }
        }
        .onChange(of: cameraShape) { _, _ in reshapeCameraPanel() }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            if countdownValue > 0 {
                Circle().fill(.orange).frame(width: 9, height: 9)
                Text("Starting...").font(.system(.subheadline, weight: .semibold)).foregroundStyle(.orange)
            } else if recorder.isRecording {
                Circle()
                    .fill(recorder.isPaused ? .orange : .red)
                    .frame(width: 9, height: 9)
                    .opacity(pulseAnimation && !recorder.isPaused ? 0.3 : 1.0)
                    .animation(
                        recorder.isPaused ? .default :
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: pulseAnimation
                    )
                    .onAppear { pulseAnimation = true }
                    .onDisappear { pulseAnimation = false }

                Text(recorder.isPaused ? "Paused" : "Recording")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(recorder.isPaused ? .orange : .red)
            } else {
                Image(systemName: "video.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                Text("FreeLum")
                    .font(.system(.subheadline, weight: .semibold))
            }

            Spacer()

            if recorder.isRecording {
                Text(formatDuration(recorder.duration))
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary.opacity(0.7))
            }
        }
    }

    // MARK: - Setup View

    private var setupView: some View {
        VStack(spacing: 8) {
            // Display
            card {
                settingRow("display", "Display") {
                    Picker("", selection: $selectedDisplayID) {
                        ForEach(recorder.availableDisplays, id: \.displayID) { d in
                            Text("\(d.width) \u{00D7} \(d.height)").tag(d.displayID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            // Camera
            card {
                settingRow("camera.fill", "Camera") {
                    Toggle("", isOn: $cameraManager.isCameraEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }

                if cameraManager.isCameraEnabled {
                    Picker("", selection: $selectedCameraID) {
                        Text("None").tag("")
                        ForEach(cameraManager.availableCameras, id: \.uniqueID) { c in
                            Text(c.localizedName).tag(c.uniqueID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    // Shape buttons
                    HStack(spacing: 6) {
                        shapeButton(.circle)
                        shapeButton(.rounded)
                        shapeButton(.pill)
                        Spacer()
                    }
                }
            }

            // Zoom on Click
            card {
                settingRow("plus.magnifyingglass", "Zoom on Click") {
                    Toggle("", isOn: $zoomOnClick)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }

            // Microphone
            card {
                settingRow("mic.fill", "Microphone") {
                    EmptyView()
                }
                Picker("", selection: $selectedMicID) {
                    Text("None").tag("")
                    ForEach(recorder.availableMicrophones, id: \.uniqueID) { m in
                        Text(m.localizedName).tag(m.uniqueID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            // Start button
            Button { startWithCountdown() } label: {
                HStack(spacing: 8) {
                    Circle().fill(.white).frame(width: 10, height: 10)
                    Text("Start Recording")
                }
                .font(.system(.body, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(recorder.availableDisplays.isEmpty)
            .padding(.top, 4)

            // Hotkey hints
            HStack(spacing: 14) {
                hotkeyBadge("\u{2318}\u{21E7}R", "Record")
                hotkeyBadge("\u{2318}\u{21E7}P", "Pause")
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Recording View

    private var recordingView: some View {
        VStack(spacing: 10) {
            // Action buttons
            HStack(spacing: 8) {
                Button {
                    recorder.togglePause()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11))
                        Text(recorder.isPaused ? "Resume" : "Pause")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await recorder.stopRecording() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11))
                        Text("Stop")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }

            // Camera card
            card {
                settingRow("camera.fill", "Camera") {
                    Toggle("", isOn: $cameraManager.isCameraEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }

                if cameraManager.isCameraEnabled {
                    HStack {
                        // Shapes
                        HStack(spacing: 4) {
                            shapeButton(.circle)
                            shapeButton(.rounded)
                            shapeButton(.pill)
                        }

                        Spacer()

                        // Corner grid
                        VStack(spacing: 1) {
                            HStack(spacing: 1) {
                                cornerButton(.topLeft)
                                cornerButton(.topRight)
                            }
                            HStack(spacing: 1) {
                                cornerButton(.bottomLeft)
                                cornerButton(.bottomRight)
                            }
                        }
                    }
                }
            }

            // Mic
            if let mic = recorder.selectedMicrophone {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text(mic.localizedName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Countdown View

    private var countdownView: some View {
        VStack(spacing: 20) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(.red.opacity(0.15), lineWidth: 5)
                    .frame(width: 100, height: 100)
                // Progress ring
                Circle()
                    .trim(from: 0, to: CGFloat(countdownValue) / 3.0)
                    .stroke(.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.8), value: countdownValue)
                // Number
                Text("\(countdownValue)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
                    .contentTransition(.numericText())
                    .animation(.easeInOut, value: countdownValue)
            }

            Button("Cancel") { cancelCountdown() }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Reusable Components

    @ViewBuilder
    private func card<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
    }

    @ViewBuilder
    private func settingRow<Trailing: View>(
        _ icon: String, _ title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(.subheadline, weight: .medium))
            Spacer()
            trailing()
        }
    }

    private func shapeButton(_ shape: CameraShape) -> some View {
        let selected = cameraShape == shape
        return Button { cameraShape = shape } label: {
            Group {
                switch shape {
                case .circle:
                    Circle().frame(width: 18, height: 18)
                case .rounded:
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .frame(width: 18, height: 18)
                case .pill:
                    Capsule().frame(width: 26, height: 16)
                }
            }
            .foregroundStyle(selected ? .red : .secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.red.opacity(0.1) : .clear)
        }
    }

    private func cornerButton(_ corner: ScreenCorner) -> some View {
        Button { moveCameraTo(corner) } label: {
            Image(systemName: corner.icon)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private func hotkeyBadge(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.quaternary)
                }
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
    }

    // MARK: - Countdown Logic

    private func startWithCountdown() {
        guard countdownValue == 0, !recorder.isRecording else { return }
        countdownTask = Task { @MainActor in
            showCountdownOverlay()
            for i in stride(from: 3, through: 1, by: -1) {
                countdownValue = i
                updateCountdownOverlayText("\(i)")
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    countdownValue = 0; hideCountdownOverlay(); return
                }
            }
            countdownValue = 0
            hideCountdownOverlay()
            recorder.zoomOnClick = zoomOnClick
            await recorder.startRecording()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel(); countdownTask = nil
        countdownValue = 0; hideCountdownOverlay()
    }

    private func showCountdownOverlay() {
        guard let screen = NSScreen.main else { return }
        let size: CGFloat = 160
        let win = NSPanel(
            contentRect: NSRect(x: screen.frame.midX - size/2, y: screen.frame.midY - size/2, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .screenSaver
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        container.layer?.cornerRadius = size / 2

        let label = NSTextField(labelWithString: "3")
        label.font = .monospacedSystemFont(ofSize: 72, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size - 90) / 2, width: size, height: 90)
        container.addSubview(label)

        win.contentView = container
        win.orderFront(nil)
        countdownWindow = win
    }

    private func updateCountdownOverlayText(_ text: String) {
        (countdownWindow?.contentView?.subviews.first as? NSTextField)?.stringValue = text
    }

    private func hideCountdownOverlay() {
        countdownWindow?.orderOut(nil); countdownWindow = nil
    }

    // MARK: - Global Hotkeys

    private func registerHotkeys() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { handleHotkey($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleHotkey($0) ? nil : $0 }
    }

    private func unregisterHotkeys() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    @discardableResult
    private func handleHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift] && event.keyCode == 15 {
            if countdownValue > 0 { cancelCountdown() }
            else if recorder.isRecording { Task { await recorder.stopRecording() } }
            else { startWithCountdown() }
            return true
        }
        if flags == [.command, .shift] && event.keyCode == 35 && recorder.isRecording {
            recorder.togglePause(); return true
        }
        return false
    }

    // MARK: - Camera Panel

    private func showCameraPanel() {
        guard cameraPanel == nil else { return }
        let h: CGFloat = 200
        let w: CGFloat = cameraShape == .pill ? h * 1.6 : h
        let shape = currentClipShape(height: h)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - w - 20,
                y: screen.visibleFrame.minY + 20
            ))
        }

        let hosting = NSHostingView(
            rootView: CameraPreview(session: cameraManager.captureSession)
                .clipShape(shape)
                .overlay { shape.stroke(.white.opacity(0.4), lineWidth: 3) }
                .shadow(color: .black.opacity(0.4), radius: 10)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: w, height: h)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.orderFront(nil)
        cameraPanel = panel
    }

    private func hideCameraPanel() { cameraPanel?.orderOut(nil); cameraPanel = nil }

    private func reshapeCameraPanel() {
        guard let panel = cameraPanel else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        hideCameraPanel(); showCameraPanel()
        if let p = cameraPanel {
            p.setFrameOrigin(NSPoint(x: center.x - p.frame.width/2, y: center.y - p.frame.height/2))
        }
    }

    private func currentClipShape(height: CGFloat) -> AnyShape {
        switch cameraShape {
        case .circle: AnyShape(Circle())
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: height * 0.15, style: .continuous))
        case .pill: AnyShape(Capsule())
        }
    }

    private func moveCameraTo(_ corner: ScreenCorner) {
        guard let panel = cameraPanel, let screen = panel.screen ?? NSScreen.main else { return }
        let m: CGFloat = 20, vis = screen.visibleFrame, w = panel.frame.width, h = panel.frame.height
        let origin: NSPoint = switch corner {
        case .topLeft:     NSPoint(x: vis.minX + m, y: vis.maxY - h - m)
        case .topRight:    NSPoint(x: vis.maxX - w - m, y: vis.maxY - h - m)
        case .bottomLeft:  NSPoint(x: vis.minX + m, y: vis.minY + m)
        case .bottomRight: NSPoint(x: vis.maxX - w - m, y: vis.minY + m)
        }
        panel.setFrame(NSRect(origin: origin, size: panel.frame.size), display: true, animate: true)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds), mins = s / 60, secs = s % 60
        if mins >= 60 { return String(format: "%d:%02d:%02d", mins/60, mins%60, secs) }
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Camera Preview

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraPreviewNSView { CameraPreviewNSView(session: session) }
    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {}
}

final class CameraPreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); previewLayer.frame = bounds }

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 5
        let curH = window.frame.height, aspect = window.frame.width / curH
        let newH = min(500, max(80, curH + delta)), newW = newH * aspect
        guard abs(newH - curH) > 0.5 else { return }
        let cx = window.frame.midX, cy = window.frame.midY
        window.setFrame(NSRect(x: cx - newW/2, y: cy - newH/2, width: newW, height: newH), display: true)
    }
}
