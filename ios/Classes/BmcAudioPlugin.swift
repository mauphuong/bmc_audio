import Flutter
import UIKit
import AVFoundation

/// BmcAudioPlugin — Native iOS audio capture with USB device support.
///
/// Three capture modes:
/// 1. AVAudioEngine (standard): Goes through CoreAudio — lossy Float32 pipeline
/// 2. CCID Audio Bridge: Bit-exact encrypted PCM via CryptoTokenKit — for iOS XOR decrypt
/// 3. USB Direct (IOKit via BmcUsbHelper): Reads raw USB isochronous data (future)
public class BmcAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - Constants
    private static let methodChannelName = "bmc_audio"
    private static let eventChannelName = "bmc_audio/audio_stream"

    // MARK: - Flutter channels
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    // MARK: - Audio engine
    private var audioEngine: AVAudioEngine?
    private var isCapturing = false

    /// The actual sample rate the hardware is delivering.
    private var actualSampleRate: Double = 16000

    // MARK: - CCID Audio Bridge (bit-exact encrypted PCM for iOS)
    private let ccidBridge = CcidAudioBridge()

    // MARK: - Plugin Registration
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = BmcAudioPlugin()

        let methodChannel = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: eventChannelName,
            binaryMessenger: registrar.messenger()
        )

        instance.methodChannel = methodChannel
        instance.eventChannel = eventChannel

        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)

        // Observe USB device hot-plug via audio route changes
        NotificationCenter.default.addObserver(
            instance,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    /// Handle audio route changes (USB device plug/unplug)
    @objc private func handleRouteChange(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        let reasonStr: String
        switch reason {
        case .newDeviceAvailable:  reasonStr = "newDeviceAvailable"
        case .oldDeviceUnavailable: reasonStr = "oldDeviceUnavailable"
        case .categoryChange:      reasonStr = "categoryChange"
        default:                   reasonStr = "other(\(reasonValue))"
        }

        NSLog("BmcAudioPlugin: Route changed: \(reasonStr)")

        // Notify Dart side so it can refresh the device list
        DispatchQueue.main.async { [weak self] in
            self?.methodChannel?.invokeMethod("onRouteChange", arguments: [
                "reason": reasonStr
            ])
        }
    }

    // MARK: - FlutterStreamHandler
    public func onListen(withArguments arguments: Any?,
                         eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // MARK: - FlutterPlugin
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)

        case "listDevices":
            result(listAudioDevices())

        case "listUsbDevices":
            result(BmcUsbHelper.listUsbDevices())

        case "startCapture":
            let sampleRate = args?["sampleRate"] as? Int ?? 16000
            let channels = args?["channels"] as? Int ?? 1
            let deviceId = args?["deviceId"] as? Int
            startCapture(deviceId: deviceId, sampleRate: sampleRate,
                         channels: channels, result: result)

        case "startCcidCapture":
            startCcidCapture(result: result)

        case "stopCapture":
            stopCapture()
            stopCcidCapture()
            result(nil)

        case "isCapturing":
            result(isCapturing)

        case "getCcidAudioStatus":
            getCcidAudioStatus(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Device Enumeration

    private func listAudioDevices() -> [[String: Any]] {
        let session = AVAudioSession.sharedInstance()
        var devices: [[String: Any]] = []

        // Activate session so iOS exposes USB audio ports in availableInputs.
        // Without this, only built-in mic shows up even when USB device is connected.
        do {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            NSLog("BmcAudioPlugin: Session activated for device listing")
        } catch {
            NSLog("BmcAudioPlugin: Session activation for device listing failed: \(error)")
        }

        // List available input ports
        guard let availableInputs = session.availableInputs else {
            return devices
        }

        for (index, port) in availableInputs.enumerated() {
            let isUsb = port.portType == .usbAudio
            let name = port.portName
            let isBmc = looksLikeBmc(name: name)

            var device: [String: Any] = [
                "id": String(index),
                "name": name,
                "type": port.portType.rawValue,
                "isUsb": isUsb,
                "isBmc": isBmc,
                "isSource": true,
                "productName": name,
            ]

            // Include UID for precise device selection
            device["uid"] = port.uid

            devices.append(device)
            NSLog("BmcAudioPlugin: Device [\(index)] \"\(name)\" type=\(port.portType.rawValue) usb=\(isUsb) bmc=\(isBmc)")
        }

        return devices
    }

    /// Heuristic to detect BMC devices by name.
    private func looksLikeBmc(name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("s-usb") ||
               lower.contains("bmc audio") ||
               lower.contains("aio") ||
               lower.contains("bmc mic")
    }

    // MARK: - Audio Capture

    private func startCapture(deviceId: Int?, sampleRate: Int, channels: Int,
                              result: @escaping FlutterResult) {
        if isCapturing {
            result(FlutterError(code: "ALREADY_CAPTURING",
                                message: "Already capturing", details: nil))
            return
        }

        do {
            // 1. Configure AVAudioSession
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])

            // CRITICAL: Use .measurement mode to disable ALL signal processing
            // (echo cancellation, AGC, noise reduction). Without this, CoreAudio
            // modifies the XOR-encrypted audio stream before we can decrypt it,
            // resulting in noise output.
            try session.setMode(.measurement)

            // Request the firmware's sample rate — iOS will use it if the USB device supports it
            try session.setPreferredSampleRate(Double(sampleRate))
            try session.setPreferredIOBufferDuration(0.02) // 20ms buffer
            try session.setActive(true)

            NSLog("BmcAudioPlugin: Session sampleRate=\(session.sampleRate), requested=\(sampleRate)")

            // Try to set input gain to maximum (1.0) for raw USB passthrough.
            // CoreAudio may apply input gain that modifies the encrypted bit pattern.
            NSLog("BmcAudioPlugin: inputGain BEFORE=\(session.inputGain), isSettable=\(session.isInputGainSettable)")
            if session.isInputGainSettable {
                try session.setInputGain(1.0)
                NSLog("BmcAudioPlugin: inputGain set to 1.0, AFTER=\(session.inputGain)")
            } else {
                NSLog("BmcAudioPlugin: ⚠️ inputGain is NOT settable")
            }

            // 2. Find and select preferred USB/BMC input port
            var preferredPort: AVAudioSessionPortDescription? = nil
            if let availableInputs = session.availableInputs {
                // Log all available inputs
                for (i, port) in availableInputs.enumerated() {
                    NSLog("BmcAudioPlugin: Available[\(i)]: \(port.portName) type=\(port.portType.rawValue)")
                }

                let bmcPort = availableInputs.first { looksLikeBmc(name: $0.portName) }
                let usbPort = availableInputs.first { $0.portType == .usbAudio }

                if let deviceId = deviceId, deviceId < availableInputs.count {
                    preferredPort = availableInputs[deviceId]
                } else {
                    preferredPort = bmcPort ?? usbPort
                }

                if let port = preferredPort {
                    try session.setPreferredInput(port)
                    NSLog("BmcAudioPlugin: Selected input: \(port.portName)")
                }
            }

            // 3. Create audio engine
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode

            // Disable voice processing (iOS 15+) to prevent modification
            // of encrypted audio stream
            if #available(iOS 15.0, *) {
                do {
                    try inputNode.setVoiceProcessingEnabled(false)
                    NSLog("BmcAudioPlugin: Voice processing disabled")
                } catch {
                    NSLog("BmcAudioPlugin: Could not disable voice processing: \(error)")
                }
            }

            // 4. Get the hardware format — this is what iOS actually delivers
            let hwFormat = inputNode.inputFormat(forBus: 0)
            actualSampleRate = hwFormat.sampleRate
            let hwChannels = hwFormat.channelCount

            NSLog("BmcAudioPlugin: Hardware format: rate=\(hwFormat.sampleRate), channels=\(hwChannels), bits=\(hwFormat.commonFormat.rawValue)")

            // 5. We tap in the NATIVE Float32 format to avoid CoreAudio's
            //    format converter which adds dithering noise during Float32→Int16
            //    conversion. Even 1-bit dither completely breaks XOR decryption.
            let tapFormat = inputNode.outputFormat(forBus: 0)

            NSLog("BmcAudioPlugin: Tap format: rate=\(tapFormat.sampleRate), channels=\(tapFormat.channelCount), commonFormat=\(tapFormat.commonFormat.rawValue)")

            // 6. If hardware rate != requested rate, log warning
            if abs(hwFormat.sampleRate - Double(sampleRate)) > 1.0 {
                NSLog("BmcAudioPlugin: ⚠️ Hardware rate (\(hwFormat.sampleRate)) != requested (\(sampleRate)). XOR decrypt may not work!")
                actualSampleRate = hwFormat.sampleRate
            }

            // 7. Install tap on input node — capture in native Float32
            let bufferSize: AVAudioFrameCount = 1024
            var chunkCount: Int64 = 0

            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) {
                [weak self] (buffer, time) in
                guard let self = self, self.isCapturing else { return }

                chunkCount += 1

                let frameCount = Int(buffer.frameLength)
                let byteCount = frameCount * 2 // 2 bytes per Int16 sample

                // Convert Float32 → PCM16LE manually (NO dithering, bit-exact)
                // Compensate for CoreAudio input gain to recover original int16 values
                if let floatData = buffer.floatChannelData {
                    // On first chunk, measure actual gain by comparing float RMS to expected
                    let inputGain = AVAudioSession.sharedInstance().inputGain
                    let gainCorrection: Float = inputGain > 0.01 ? 1.0 / Float(inputGain) : 1.0

                    var data = Data(count: byteCount)
                    data.withUnsafeMutableBytes { rawPtr in
                        let int16Ptr = rawPtr.bindMemory(to: Int16.self)
                        for i in 0..<frameCount {
                            // Undo CoreAudio gain: divide by inputGain to recover original
                            // Then multiply by 32768 to get back to int16 range
                            let f = floatData[0][i] * gainCorrection
                            let scaled = f * 32768.0
                            let clamped = max(-32768.0, min(32767.0, scaled))
                            int16Ptr[i] = Int16(clamped)
                        }
                    }

                    // Diagnostic on first chunk
                    if chunkCount == 1 {
                        let hexBytes = data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
                        NSLog("BmcAudioPlugin: First chunk raw hex (PCM16LE): \(hexBytes)")

                        let floatSamples = (0..<min(8, frameCount)).map { String(format: "%.6f", floatData[0][$0]) }.joined(separator: ", ")
                        NSLog("BmcAudioPlugin: First float samples: \(floatSamples)")

                        // RMS + max amplitude to verify if data is encrypted
                        var maxAmp: Float = 0
                        var sumSq: Float = 0
                        for i in 0..<frameCount {
                            let f = abs(floatData[0][i])
                            if f > maxAmp { maxAmp = f }
                            sumSq += floatData[0][i] * floatData[0][i]
                        }
                        let rms = (sumSq / Float(frameCount)).squareRoot()
                        NSLog("BmcAudioPlugin: ⚡ RAW float: RMS=\(String(format: "%.6f", rms)), maxAmp=\(String(format: "%.6f", maxAmp))")
                        NSLog("BmcAudioPlugin: ⚡ inputGain=\(String(format: "%.6f", AVAudioSession.sharedInstance().inputGain)), gainCorrection=\(String(format: "%.6f", 1.0 / AVAudioSession.sharedInstance().inputGain))")
                        NSLog("BmcAudioPlugin: ⚡ Expected: raw RMS≈0.577 for random int16; corrected RMS should be ≈0.577")

                        // Also verify the CORRECTED values
                        let gain = AVAudioSession.sharedInstance().inputGain
                        let gc: Float = gain > 0.01 ? 1.0 / Float(gain) : 1.0
                        let correctedSamples = (0..<min(8, frameCount)).map { String(format: "%d", Int16(max(-32768.0, min(32767.0, floatData[0][$0] * gc * 32768.0)))) }.joined(separator: ", ")
                        NSLog("BmcAudioPlugin: ⚡ Corrected int16 samples: \(correctedSamples)")

                        // Log ACTUAL current route to confirm we're reading from USB
                        let route = AVAudioSession.sharedInstance().currentRoute
                        let inputs = route.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }
                        NSLog("BmcAudioPlugin: ⚡ ACTUAL capture source: \(inputs)")
                    }

                    let flutterData = FlutterStandardTypedData(bytes: data)

                    if chunkCount <= 5 || chunkCount % 100 == 0 {
                        NSLog("BmcAudioPlugin: Chunk #\(chunkCount): \(byteCount) bytes, frames=\(frameCount)")
                    }

                    // Send to Dart on main thread
                    DispatchQueue.main.async {
                        self.eventSink?(flutterData)
                    }
                } else if let int16Data = buffer.int16ChannelData {
                    // Fallback: hardware already delivers Int16
                    let data = Data(bytes: int16Data[0], count: byteCount)
                    let flutterData = FlutterStandardTypedData(bytes: data)

                    if chunkCount <= 5 || chunkCount % 100 == 0 {
                        NSLog("BmcAudioPlugin: Chunk #\(chunkCount): \(byteCount) bytes (int16 native)")
                    }

                    DispatchQueue.main.async {
                        self.eventSink?(flutterData)
                    }
                } else {
                    NSLog("BmcAudioPlugin: No audio data available in buffer")
                }
            }

            // 8. Start engine
            try engine.start()
            audioEngine = engine
            isCapturing = true

            // 9. CRITICAL: Verify audio route AFTER engine start.
            //    engine.start() triggers route changes that may reset input
            //    back to built-in microphone.
            let currentRoute = session.currentRoute
            let actualInputs = currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }
            NSLog("BmcAudioPlugin: Route after engine start: \(actualInputs)")

            if let preferredPort = preferredPort {
                let isUsingPreferred = currentRoute.inputs.contains { $0.uid == preferredPort.uid }
                if !isUsingPreferred {
                    NSLog("BmcAudioPlugin: ⚠️ Route changed away from \(preferredPort.portName)! Re-asserting...")
                    try session.setPreferredInput(preferredPort)
                    let newRoute = session.currentRoute
                    let newInputs = newRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }
                    NSLog("BmcAudioPlugin: Route after re-assert: \(newInputs)")
                }
            }

            NSLog("BmcAudioPlugin: ✓ Capture started (rate=\(actualSampleRate))")

            result([
                "sampleRate": actualSampleRate,
                "hardwareSampleRate": hwFormat.sampleRate,
                "channels": channels,
                "rateMatch": abs(hwFormat.sampleRate - Double(sampleRate)) < 1.0,
            ])

        } catch {
            NSLog("BmcAudioPlugin: FAILED to start capture: \(error)")
            result(FlutterError(code: "CAPTURE_ERROR",
                                message: "Failed to start capture: \(error.localizedDescription)",
                                details: nil))
        }
    }

    private func stopCapture() {
        guard isCapturing else { return }

        isCapturing = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // CRITICAL: Reset audio session for playback.
        // During capture we use .measurement mode which disables all signal
        // processing. After stopping, we must reset to .playback/.default so
        // that just_audio (and other audio players) can function properly.
        // Without this, the session remains in a state where the audio player
        // gets err=-12860 on subsequent playback attempts.
        let session = AVAudioSession.sharedInstance()
        do {
            // First deactivate to release recording resources
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            // Reset to playback-friendly configuration
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            NSLog("BmcAudioPlugin: Session reset to playback mode")
        } catch {
            NSLog("BmcAudioPlugin: Session reset error: \(error)")
            // Fallback: just deactivate
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }

        NSLog("BmcAudioPlugin: Capture stopped")
    }

    // MARK: - Cleanup
    deinit {
        stopCapture()
        stopCcidCapture()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - CCID Audio Capture (bit-exact encrypted PCM)

    /// Start audio capture via CCID tunnel.
    /// This bypasses CoreAudio entirely — encrypted PCM16LE is read bit-exact
    /// from the firmware's ring buffer via CryptoTokenKit APDU.
    private func startCcidCapture(result: @escaping FlutterResult) {
        if isCapturing {
            result(FlutterError(code: "ALREADY_CAPTURING",
                                message: "Already capturing", details: nil))
            return
        }

        // Connect to smart card (always reconnect fresh to handle device removal)
        ccidBridge.disconnect()
        guard ccidBridge.connect() else {
            NSLog("BmcAudioPlugin: CCID connect failed")
            result(FlutterError(code: "CCID_CONNECT_FAILED",
                                message: "Could not connect to smart card", details: nil))
            return
        }

        // Check status before starting
        if let status = ccidBridge.getStatus() {
            NSLog("BmcAudioPlugin: CCID status before start: avail=\(status.avail) rate=\(status.sampleRate) enc=\(status.encrypted) streaming=\(status.streaming)")
        }

        // ── CRITICAL: Activate AVAudioEngine to keep UAC endpoint alive ──
        // The firmware ring buffer is populated from USB_AudioRecorderGetBuffer(),
        // which is only called when the USB audio isochronous endpoint is streaming.
        // We must start AVAudioEngine so iOS requests audio from the UAC interface,
        // triggering the firmware to generate packets → fill ring buffer → CCID reads it.
        // The AVAudioEngine data itself is DISCARDED (lossy Float32); we only use the
        // bit-exact CCID data.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                     options: [.allowBluetooth, .defaultToSpeaker])
            try session.setPreferredSampleRate(16000)
            try session.setActive(true)

            // Select S-USB AIO input
            if let inputs = session.availableInputs {
                for input in inputs where input.portType == .usbAudio {
                    try session.setPreferredInput(input)
                    NSLog("BmcAudioPlugin: CCID: Selected USB input: \(input.portName)")
                    break
                }
            }

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let fmt = inputNode.outputFormat(forBus: 0)

            // Install a silent tap — discard all data
            inputNode.installTap(onBus: 0, bufferSize: 1600, format: fmt) { _, _ in
                // Intentionally empty — data is discarded.
                // We only need AVAudioEngine running to keep the UAC endpoint active.
            }

            try engine.start()
            audioEngine = engine
            NSLog("BmcAudioPlugin: CCID: AVAudioEngine started (UAC keepalive, format=\(fmt))")
        } catch {
            NSLog("BmcAudioPlugin: CCID: ⚠️ AVAudioEngine failed: \(error) — ring buffer may be empty")
        }

        // Start encrypted audio stream on firmware
        guard ccidBridge.startStream() else {
            result(FlutterError(code: "CCID_START_FAILED",
                                message: "Could not start CCID audio stream", details: nil))
            return
        }

        isCapturing = true

        // Set up polling — receive encrypted PCM chunks and forward to Dart
        var chunkCount: Int64 = 0
        ccidBridge.onAudioData = { [weak self] data in
            guard let self = self, self.isCapturing else { return }
            chunkCount += 1

            let flutterData = FlutterStandardTypedData(bytes: data)

            if chunkCount <= 5 || chunkCount % 100 == 0 {
                NSLog("BmcAudioPlugin: CCID chunk #\(chunkCount): \(data.count) bytes")
            }

            DispatchQueue.main.async {
                self.eventSink?(flutterData)
            }
        }

        // Poll every 20ms (~50 Hz) — balances latency vs CPU usage
        ccidBridge.startPolling(intervalMs: 20)

        NSLog("BmcAudioPlugin: ✓ CCID capture started (encrypted, bit-exact)")

        result([
            "sampleRate": 16000,
            "channels": 1,
            "mode": "ccid",
        ])
    }

    /// Stop CCID audio capture.
    private func stopCcidCapture() {
        ccidBridge.stopStream()
        ccidBridge.onAudioData = nil

        // Stop AVAudioEngine UAC keepalive
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // CRITICAL: Reset audio session for playback after CCID capture.
        // Same issue as stopCapture() — the session is left in .measurement
        // mode with .playAndRecord category, which causes just_audio to fail
        // with err=-12860 on subsequent playback attempts.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            NSLog("BmcAudioPlugin: CCID session reset to playback mode")
        } catch {
            NSLog("BmcAudioPlugin: CCID session reset error: \(error)")
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }

        NSLog("BmcAudioPlugin: CCID capture stopped")
    }

    /// Get CCID audio stream status (for diagnostics).
    private func getCcidAudioStatus(result: @escaping FlutterResult) {
        guard let status = ccidBridge.getStatus() else {
            result(nil)
            return
        }
        result([
            "avail": status.avail,
            "sampleRate": status.sampleRate,
            "encrypted": status.encrypted,
            "streaming": status.streaming,
            "ringSize": status.ringSize,
        ])
    }
}

