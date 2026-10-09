import SwiftUI
import AVFoundation

let cameraTitle = "HD Camera USC-CAM"

@main
struct USCCamApp: App {
    @StateObject private var camera = CameraManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .preferredColorScheme(.dark)
                .onAppear { camera.start() }
        }
    }
}

// MARK: - Live camera preview

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshOrientation),
                                               name: .AVCaptureSessionDidStartRunning, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() { super.didMoveToWindow(); refreshOrientation() }
    override func layoutSubviews() { super.layoutSubviews(); refreshOrientation() }

    @objc func refreshOrientation() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let conn = self.previewLayer.connection,
                  conn.isVideoOrientationSupported else { return }
            let o = self.window?.windowScene?.interfaceOrientation ?? .portrait
            switch o {
            case .landscapeLeft:       conn.videoOrientation = .landscapeLeft
            case .landscapeRight:      conn.videoOrientation = .landscapeRight
            case .portraitUpsideDown:  conn.videoOrientation = .portraitUpsideDown
            default:                   conn.videoOrientation = .portrait
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect      // whole frame, same field of view the PC gets
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.refreshOrientation()
    }
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject var camera: CameraManager
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = 0.5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                controls
            }

            if dimmed {
                Color.black.ignoresSafeArea()
                    .overlay(Text("Tap to wake").font(.footnote).foregroundColor(Color.white.opacity(0.25)))
                    .onTapGesture { setDimmed(false) }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(cameraTitle)
                .font(.system(size: 18, weight: .bold))
                .tracking(1.5)
            statusPill
        }
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("RESOLUTION").font(.system(size: 11, weight: .semibold)).tracking(2).foregroundColor(.gray)
                Picker("Resolution", selection: Binding(
                    get: { camera.selectedResolution },
                    set: { camera.setResolution($0) })) {
                    ForEach(camera.availableResolutions) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CODEC").font(.system(size: 11, weight: .semibold)).tracking(2).foregroundColor(.gray)
                Picker("Codec", selection: Binding(
                    get: { camera.selectedCodec },
                    set: { camera.setCodec($0) })) {
                    ForEach(StreamCodec.allCases) { c in Text(c.rawValue).tag(c) }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("FRAME RATE").font(.system(size: 11, weight: .semibold)).tracking(2).foregroundColor(.gray)
                Picker("Frame rate", selection: Binding(
                    get: { camera.selectedFPS },
                    set: { camera.setFPS($0) })) {
                    ForEach(camera.availableFPS, id: \.self) { f in Text("\(f) fps").tag(f) }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("QUALITY").font(.system(size: 11, weight: .semibold)).tracking(2).foregroundColor(.gray)
                Picker("Quality", selection: Binding(
                    get: { camera.selectedQuality },
                    set: { camera.setQuality($0) })) {
                    ForEach(StreamQuality.allCases) { q in Text(q.rawValue).tag(q) }
                }
                .pickerStyle(.segmented)
            }

            Text("\(camera.resolution)  ·  \(camera.pcConnected ? "\(camera.fps) fps" : "no PC")  ·  \(camera.usingFrontCamera ? "Front" : "Back") camera")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gray)

            HStack(spacing: 12) {
                button("Flip camera", "arrow.triangle.2.circlepath.camera") { camera.flipCamera() }
                button("Dim screen", "moon.fill") { setDimmed(true) }
            }

            Text("Wi-Fi: \(camera.wifiAddress)  ·  port 9999")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gray)

            Text("Keep this app open. iOS pauses the camera in the background.\nLower quality = smaller frames = less lag over USB.")
                .font(.caption2)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .foregroundColor(.white)
        .padding(16)
        .frame(maxWidth: 520)
        .background(Color.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch camera.phase {
            case .denied:   return ("Camera access denied - enable it in Settings", .red)
            case .noCamera: return ("No camera available", .red)
            case .starting: return ("Starting...", .orange)
            case .running:  return camera.pcConnected ? ("Streaming to PC", .green)
                                                      : ("Ready - waiting for PC", .orange)
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.system(size: 13, weight: .semibold))
        }
    }

    private func button(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.white)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func setDimmed(_ on: Bool) {
        if on { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = on ? 0.0 : savedBrightness
        dimmed = on
    }
}
