import AVFoundation
import UIKit
import Network
import ImageIO
import VideoToolbox

enum StreamResolution: String, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case uhd4k = "4K"

    var id: String { rawValue }
    var size: (w: Int32, h: Int32) {
        switch self {
        case .hd720:  return (1280, 720)
        case .hd1080: return (1920, 1080)
        case .uhd4k:  return (3840, 2160)
        }
    }
}

/// Frame rates offered in the UI (only those the camera really supports are shown).
let streamFPSOptions = [120, 60, 30]

enum StreamQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }
    var jpeg: Double {
        switch self {
        case .low:    return 0.6
        case .medium: return 0.75
        case .high:   return 0.9
        }
    }
    /// H.264 bits per pixel per frame: 1080p120 -> about 25 / 40 / 62 Mbit/s.
    var bitsPerPixel: Double {
        switch self {
        case .low:    return 0.10
        case .medium: return 0.16
        case .high:   return 0.25
        }
    }
}

enum StreamCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case mjpeg = "MJPEG"
    var id: String { rawValue }
}

/// Captures video from the iPhone camera and serves it over TCP port 9999, either through the
/// USB cable (usbmuxd) or over Wi-Fi (PC connects to the iPhone's IP).
/// Wire format, repeated: [4 bytes big-endian N][1 byte codec: 0 = JPEG, 1 = H.264 Annex-B access unit][N-1 bytes].
/// The PC answers every received frame with one byte (flow control).
final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Phase { case starting, denied, noCamera, running }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var pcConnected = false
    @Published private(set) var resolution = "-"
    @Published private(set) var fps = 0
    @Published private(set) var usingFrontCamera = false
    @Published private(set) var selectedResolution: StreamResolution = .hd1080
    @Published private(set) var selectedQuality: StreamQuality = .medium
    @Published private(set) var availableResolutions: [StreamResolution] = StreamResolution.allCases
    @Published private(set) var selectedFPS = 120
    @Published private(set) var availableFPS: [Int] = streamFPSOptions
    @Published private(set) var selectedCodec: StreamCodec = .h264
    @Published private(set) var wifiAddress = "-"

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "usc.session")
    private let frameQueue = DispatchQueue(label: "usc.frames", qos: .userInteractive)
    private let netQueue = DispatchQueue(label: "usc.net")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let output = AVCaptureVideoDataOutput()

    private var listener: NWListener?
    private var connection: NWConnection?
    private var configured = false

    private let lock = NSLock()
    private var inFlight = 0
    private var frameCounter = 0
    private var lastFpsTick = CACurrentMediaTime()
    private var qualityValue: Double = StreamQuality.medium.jpeg   // guarded by `lock`
    private var desiredResolution: StreamResolution = .hd1080      // sessionQueue only
    private var desiredFPS = 120                                   // sessionQueue only
    private var effectiveResolution: StreamResolution = .hd1080    // sessionQueue only
    private var effectiveFPS = 30                                  // sessionQueue only
    private var ackMode = false                                    // guarded by `lock`
    private let maxInFlight = 3
    private var codecValue: StreamCodec = .h264                    // guarded by `lock`
    private var encoderDirty = true                                // guarded by `lock`
    private var forceKey = true                                    // guarded by `lock`
    private var encFPS = 30                                        // guarded by `lock`
    private var vtSession: VTCompressionSession?                   // frameQueue only
    private var encW: Int32 = 0                                    // frameQueue only
    private var encH: Int32 = 0                                    // frameQueue only
    private var addressTimer: Timer?
    private var isFront = false                                    // sessionQueue only

    override init() {
        let d = UserDefaults.standard
        let r = StreamResolution(rawValue: d.string(forKey: "usc.resolution") ?? "") ?? .hd1080
        let q = StreamQuality(rawValue: d.string(forKey: "usc.quality") ?? "") ?? .medium
        let f = d.integer(forKey: "usc.fps")
        let fps = streamFPSOptions.contains(f) ? f : 120
        selectedResolution = r
        selectedQuality = q
        selectedFPS = fps
        desiredFPS = fps
        desiredResolution = r
        qualityValue = q.jpeg
        let c = StreamCodec(rawValue: d.string(forKey: "usc.codec") ?? "") ?? .h264
        selectedCodec = c
        codecValue = c
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        refreshAddress()
        addressTimer?.invalidate()
        addressTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshAddress()
        }
        startListener()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                ok ? self?.configureAndRun() : self?.setPhase(.denied)
            }
        default:
            setPhase(.denied)
        }
    }

    // MARK: User settings (phone UI)

    func setResolution(_ r: StreamResolution) {
        UserDefaults.standard.set(r.rawValue, forKey: "usc.resolution")
        DispatchQueue.main.async { self.selectedResolution = r }
        sessionQueue.async { [weak self] in
            guard let self = self, self.configured else { self?.desiredResolution = r; return }
            self.desiredResolution = r
            self.reconfigure()
        }
    }

    func setFPS(_ f: Int) {
        UserDefaults.standard.set(f, forKey: "usc.fps")
        DispatchQueue.main.async { self.selectedFPS = f }
        sessionQueue.async { [weak self] in
            guard let self = self, self.configured else { self?.desiredFPS = f; return }
            self.desiredFPS = f
            self.reconfigure()
        }
    }

    func setQuality(_ q: StreamQuality) {
        UserDefaults.standard.set(q.rawValue, forKey: "usc.quality")
        lock.lock(); qualityValue = q.jpeg; encoderDirty = true; lock.unlock()
        DispatchQueue.main.async { self.selectedQuality = q }
        sessionQueue.async { [weak self] in
            guard let self = self, self.configured else { return }
            self.session.beginConfiguration()
            self.applyVideoSettings()
            self.session.commitConfiguration()
        }
    }

    func setCodec(_ c: StreamCodec) {
        UserDefaults.standard.set(c.rawValue, forKey: "usc.codec")
        lock.lock(); codecValue = c; encoderDirty = true; forceKey = true; lock.unlock()
        DispatchQueue.main.async { self.selectedCodec = c }
        sessionQueue.async { [weak self] in
            guard let self = self, self.configured else { return }
            self.session.beginConfiguration()
            self.applyVideoSettings()
            self.session.commitConfiguration()
            self.tuneConnection()
        }
    }

    func flipCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let front = !self.isFront
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            if self.addInput(front: front) {
                self.isFront = front
                DispatchQueue.main.async { self.usingFrontCamera = front }
            } else {
                _ = self.addInput(front: !front)
            }
            self.session.commitConfiguration()
            self.reconfigure()
        }
    }

    // MARK: Camera

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.configured {
                self.session.beginConfiguration()
                guard self.addInput(front: false) else {
                    self.session.commitConfiguration()
                    self.setPhase(.noCamera)
                    return
                }
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                self.session.commitConfiguration()
                self.configured = true
                // Pick the camera format (resolution + up to 120 fps), then the hardware JPEG
                // encoder (its codec list depends on the active format).
                self.reconfigure()
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.updateResolutionLabel()
            self.setPhase(.running)
        }
    }

    @discardableResult
    private func addInput(front: Bool) -> Bool {
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        return true
    }

    private var currentDevice: AVCaptureDevice? {
        (session.inputs.first as? AVCaptureDeviceInput)?.device
    }

    /// Best 8-bit format for `res` that can run at `fps` (widest field of view wins).
    private func bestFormat(_ device: AVCaptureDevice, _ res: StreamResolution, _ fps: Int) -> AVCaptureDevice.Format? {
        let want = Double(fps)
        let matching = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == res.size.w && d.height == res.size.h &&
                f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= want && $0.maxFrameRate >= want }
        }
        let eightBit = matching.filter { f in
            let t = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return t == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                   t == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        let pool = eightBit.isEmpty ? matching : eightBit
        return pool.max { $0.videoFieldOfView < $1.videoFieldOfView }
    }

    /// Chooses the best format: highest fps first (up to the wanted one), then the wanted
    /// resolution or the next lower one that can do that fps.
    private func applyFormat() {
        guard let device = currentDevice else { return }
        let order: [StreamResolution] = [.uhd4k, .hd1080, .hd720]
        let start = order.firstIndex(of: desiredResolution) ?? 1
        for fps in streamFPSOptions where fps <= desiredFPS {
            for r in order[start...] {
                guard let format = bestFormat(device, r, fps) else { continue }
                guard (try? device.lockForConfiguration()) != nil else { return }
                device.activeFormat = format
                let d = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMinFrameDuration = d      // fixed rate = steady pacing
                device.activeVideoMaxFrameDuration = d
                if device.activeFormat.isVideoHDRSupported {  // HDR tone mapping adds latency
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = false
                }
                device.unlockForConfiguration()
                effectiveResolution = r
                effectiveFPS = fps
                return
            }
        }
    }

    /// Format + encoder + connection tuning + UI state. Call on `sessionQueue`.
    private func reconfigure() {
        applyFormat()
        lock.lock(); encFPS = effectiveFPS; encoderDirty = true; lock.unlock()
        session.beginConfiguration()
        applyVideoSettings()
        session.commitConfiguration()
        tuneConnection()
        publishAvailable()
        updateResolutionLabel()
    }

    /// Video stabilization buffers several frames -> noticeable lag. Turn it off.
    private func tuneConnection() {
        if let c = output.connection(with: .video), c.isVideoStabilizationSupported {
            c.preferredVideoStabilizationMode = .off
        }
    }

    private func applyVideoSettings() {
        lock.lock(); let q = qualityValue; let codec = codecValue; lock.unlock()
        if codec == .h264 {
            // Raw frames for the hardware H.264 encoder (VideoToolbox).
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            return
        }
        // MJPEG: hardware JPEG encoder, far faster than converting every frame on the CPU.
        if output.availableVideoCodecTypes.contains(.jpeg) {
            output.videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.jpeg,
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: q]
            ]
        }
    }

    private func publishAvailable() {
        guard let device = currentDevice else { return }
        let fpsNow = effectiveFPS
        let resList = StreamResolution.allCases.filter { bestFormat(device, $0, fpsNow) != nil }
        let fpsList = streamFPSOptions.filter { f in
            StreamResolution.allCases.contains { bestFormat(device, $0, f) != nil }
        }
        let res = effectiveResolution
        DispatchQueue.main.async {
            self.availableResolutions = resList.isEmpty ? [.hd720] : resList
            self.availableFPS = fpsList.isEmpty ? [30] : fpsList
            self.selectedResolution = res
            self.selectedFPS = fpsNow
        }
    }

    private func updateResolutionLabel() {
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        DispatchQueue.main.async { self.resolution = "\(d.width)x\(d.height)" }
    }

    private func setPhase(_ p: Phase) {
        DispatchQueue.main.async { self.phase = p }
    }

    // MARK: Network (USB tunnel endpoint)

    private func startListener() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }
            let l = try NWListener(using: params, on: 9999)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.listener?.cancel()
                    self?.listener = nil
                    self?.netQueue.asyncAfter(deadline: .now() + 1) { self?.startListener() }
                }
            }
            l.start(queue: netQueue)
            listener = l
        } catch {
            netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startListener() }
        }
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        lock.lock(); inFlight = 0; ackMode = false; forceKey = true; lock.unlock()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            switch state {
            case .ready: DispatchQueue.main.async { self.pcConnected = true }
            case .failed, .cancelled: DispatchQueue.main.async { self.pcConnected = false }
            default: break
            }
        }
        conn.start(queue: netQueue)
        receiveAcks(conn)
    }

    /// The PC answers every received frame with one byte. Counting unacknowledged frames
    /// (instead of "handed to the kernel") keeps the USB pipe from filling with old frames.
    private func receiveAcks(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self, weak conn] data, _, done, error in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            if let n = data?.count, n > 0 {
                self.lock.lock()
                self.ackMode = true
                self.inFlight = max(0, self.inFlight - n)
                self.lock.unlock()
            }
            if error == nil && !done { self.receiveAcks(conn) }
        }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let conn = self.connection, conn.state == .ready else { return }

        lock.lock()
        if inFlight >= maxInFlight {          // PC/link can't keep up -> drop frame, keep latency low
            lock.unlock()
            return
        }
        inFlight += 1
        let codec = codecValue
        lock.unlock()

        switch codec {
        case .mjpeg:
            guard let jpeg = jpegData(from: sampleBuffer) else { releaseSlot(); return }
            sendPacket(conn, codec: 0, payload: jpeg)
        case .h264:
            encode(sampleBuffer)
        }
    }

    private func releaseSlot() {
        lock.lock(); inFlight = max(0, inFlight - 1); lock.unlock()
    }

    private func sendPacket(_ conn: NWConnection, codec: UInt8, payload: Data) {
        var length = UInt32(payload.count + 1).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(codec)
        packet.append(payload)
        conn.send(content: packet, completion: .contentProcessed { [weak self] _ in
            // Old PC app without acks: fall back to "handed to the kernel" accounting.
            guard let self = self else { return }
            self.lock.lock()
            if !self.ackMode { self.inFlight = max(0, self.inFlight - 1) }
            self.lock.unlock()
        })
        tickFps()
    }

    // MARK: H.264 (VideoToolbox, low-latency, no B-frames)

    private func encode(_ sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { releaseSlot(); return }
        let w = Int32(CVPixelBufferGetWidth(pb))
        let h = Int32(CVPixelBufferGetHeight(pb))
        lock.lock()
        let dirty = encoderDirty; encoderDirty = false
        let key = forceKey; forceKey = false
        let fps = encFPS
        let q = selectedQualityLocked
        lock.unlock()
        if dirty || vtSession == nil || w != encW || h != encH {
            let rate = Double(w) * Double(h) * Double(fps) * q.bitsPerPixel
            rebuildEncoder(w, h, fps: fps, bitrate: Int(min(max(rate, 4_000_000), 90_000_000)))
        }
        guard let session = vtSession else { releaseSlot(); return }
        let props: CFDictionary? = key ? ([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary) : nil
        let st = VTCompressionSessionEncodeFrame(session,
                                                 imageBuffer: pb,
                                                 presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
                                                 duration: CMSampleBufferGetDuration(sb),
                                                 frameProperties: props,
                                                 infoFlagsOut: nil) { [weak self] status, _, out in
            self?.encoded(status, out)
        }
        if st != noErr { releaseSlot() }
    }

    private var selectedQualityLocked: StreamQuality {
        // `qualityValue` is the only quality state shared with this queue.
        StreamQuality.allCases.first { $0.jpeg == qualityValue } ?? .medium
    }

    private func rebuildEncoder(_ w: Int32, _ h: Int32, fps: Int, bitrate: Int) {
        destroyEncoder()
        var created: VTCompressionSession?
        let spec: [String: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true]
        let st = VTCompressionSessionCreate(allocator: nil, width: w, height: h,
                                            codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil,
                                            compressionSessionOut: &created)
        guard st == noErr, let session = created else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: max(fps, 30)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTCompressionSessionPrepareToEncodeFrames(session)
        vtSession = session
        encW = w
        encH = h
    }

    private func destroyEncoder() {
        if let s = vtSession {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)  // flush -> no leaked slots
            VTCompressionSessionInvalidate(s)
        }
        vtSession = nil
    }

    /// Encoder output (AVCC, length-prefixed) -> Annex-B access unit; SPS/PPS in front of key frames.
    private func encoded(_ status: OSStatus, _ sb: CMSampleBuffer?) {
        guard status == noErr, let sb = sb, CMSampleBufferDataIsReady(sb),
              let conn = self.connection, conn.state == .ready,
              let block = CMSampleBufferGetDataBuffer(sb) else { releaseSlot(); return }

        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var index = 0
            var count = 0
            repeat {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let r = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: index,
                                                                           parameterSetPointerOut: &ptr,
                                                                           parameterSetSizeOut: &size,
                                                                           parameterSetCountOut: &count,
                                                                           nalUnitHeaderLengthOut: nil)
                if r == noErr, let p = ptr {
                    out.append(contentsOf: startCode)
                    out.append(p, count: size)
                }
                index += 1
            } while index < count
        }

        var total = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &total, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
              let base = dataPtr else { releaseSlot(); return }
        let raw = UnsafeRawPointer(base)
        var offset = 0
        while offset + 4 <= total {
            var be: UInt32 = 0
            memcpy(&be, raw + offset, 4)
            let len = Int(UInt32(bigEndian: be))
            offset += 4
            guard len > 0, offset + len <= total else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: len))
            offset += len
        }
        if out.isEmpty { releaseSlot(); return }
        sendPacket(conn, codec: 1, payload: out)
    }

    // MARK: Wi-Fi address (shown on screen so the PC app can connect without USB)

    private func refreshAddress() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let a = CameraManager.localWiFiAddress()
            DispatchQueue.main.async { self?.wifiAddress = a }
        }
    }

    private static func localWiFiAddress() -> String {
        var found = "no Wi-Fi"
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return found }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    found = String(cString: host)
                }
            }
            cursor = ifa.ifa_next
        }
        return found
    }

    private func jpegData(from sampleBuffer: CMSampleBuffer) -> Data? {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Fallback path (raw pixels): encode with Core Image.
            lock.lock(); let q = qualityValue; lock.unlock()
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            return ciContext.jpegRepresentation(of: image, colorSpace: space,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: q])
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let p = pointer, length > 0 else { return nil }
        return Data(bytes: p, count: length)
    }

    private func tickFps() {
        frameCounter += 1
        let now = CACurrentMediaTime()
        if now - lastFpsTick >= 1 {
            let value = Int((Double(frameCounter) / (now - lastFpsTick)).rounded())
            frameCounter = 0
            lastFpsTick = now
            DispatchQueue.main.async { self.fps = value }
        }
    }
}
