import Flutter
import UIKit
import AVFoundation

/// BMC Audio Plugin — Native iOS audio capture using AVAudioEngine.
///
/// Uses AVAudioEngine to capture audio at the hardware's native format,
/// avoiding Core Audio resampling that would destroy XOR-encrypted PCM data
/// from the BMC USB Audio device.
public class BmcAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - Constants
    private static let methodChannelName = "bmc_audio"
    private static let eventChannelName = "bmc_audio/audio_stream"

    // MARK: - Flutter channels
/// BmcAudioPlugin — Native iOS audio capture with USB device support.
///
/// Two capture modes:
/// 1. AVAudioEngine (standard): Goes through CoreAudio
/// 2. USB Direct (IOKit via BmcUsbHelper): Reads raw USB isochronous data
public class BmcAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    // MARK: - Audio engine
    private var audioEngine: AVAudioEngine?
    private var isCapturing = false

    /// The actual sample rate the hardware is delivering.
    private var actualSampleRate: Double = 16000

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
        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)

        case "listDevices":
            result(listAudioDevices())

        case "startCapture":
            let args = call.arguments as? [String: Any]
            let sampleRate = args?["sampleRate"] as? Int ?? 16000
            let channels = args?["channels"] as? Int ?? 1
            startCapture(sampleRate: sampleRate, channels: channels, result: result)

        case "isCapturing":
            result(isCapturing)
            let deviceId = args?["deviceId"] as? Int
            startCapture(deviceId: deviceId, sampleRate: sampleRate,
                         channels: channels, result: result)

        case "startUsbCapture":
            let args = call.arguments as? [String: Any]
            let vid = args?["vendorId"] as? Int ?? 0x1fc9
            let pid = args?["productId"] as? Int ?? 0x0117
            startUsbDirectCapture(vid: UInt16(vid), pid: UInt16(pid), result: result)

        case "stopCapture":
            stopCapture()
            BmcUsbHelper.stopIsocCapture()
            result(nil)

        case "isCapturing":
            result(isCapturing || BmcUsbHelper.isCapturing())

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Device Enumeration

    private func listAudioDevices() -> [[String: Any]] {
        let session = AVAudioSession.sharedInstance()
        var devices: [[String: Any]] = []

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

    private func startCapture(sampleRate: Int, channels: Int, result: @escaping FlutterResult) {
        if isCapturing {
            result(FlutterError(code: "ALREADY_CAPTURING",
                                message: "Already capturing", details: nil))
            return
        }

        do {
            // 1. Configure AVAudioSession
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])

            // Request the firmware's sample rate — iOS will use it if the USB device supports it
            try session.setPreferredSampleRate(Double(sampleRate))
            try session.setPreferredIOBufferDuration(0.02) // 20ms buffer
            try session.setActive(true)

            NSLog("BmcAudioPlugin: Session sampleRate=\(session.sampleRate), requested=\(sampleRate)")

            // 2. Try to select USB audio input if available
            if let availableInputs = session.availableInputs {
                // Prefer BMC device, then any USB, then default
                let bmcPort = availableInputs.first { looksLikeBmc(name: $0.portName) }
                let usbPort = availableInputs.first { $0.portType == .usbAudio }
                if let preferredPort = bmcPort ?? usbPort {
                    try session.setPreferredInput(preferredPort)
                    NSLog("BmcAudioPlugin: Selected input: \(preferredPort.portName)")
                }
            }

            // 3. Create audio engine
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode

            // 4. Get the hardware format — this is what iOS actually delivers
            let hwFormat = inputNode.inputFormat(forBus: 0)
            actualSampleRate = hwFormat.sampleRate
            let hwChannels = hwFormat.channelCount

            NSLog("BmcAudioPlugin: Hardware format: rate=\(hwFormat.sampleRate), channels=\(hwChannels), bits=\(hwFormat.commonFormat.rawValue)")

            // 5. Create desired output format — PCM Int16 LE at hardware rate
            //    We do NOT change the sample rate here to avoid resampling!
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: hwFormat.sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: true
            ) else {
                result(FlutterError(code: "FORMAT_ERROR",
                                    message: "Failed to create output format", details: nil))
                return
            }

            NSLog("BmcAudioPlugin: Output format: rate=\(outputFormat.sampleRate), channels=\(outputFormat.channelCount), int16le")

            // 6. If hardware rate != requested rate, we need a converter
            //    This is for the case where iOS forces 48kHz
            var converter: AVAudioConverter? = nil
            if abs(hwFormat.sampleRate - Double(sampleRate)) > 1.0 {
                // Hardware rate is different from requested — need to convert
                // First, create an intermediate format at hardware rate with Int16
                guard let hwInt16Format = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: hwFormat.sampleRate,
                    channels: AVAudioChannelCount(channels),
                    interleaved: true
                ) else {
                    result(FlutterError(code: "FORMAT_ERROR",
                                        message: "Failed to create hw int16 format", details: nil))
                    return
                }

                // Create target format at requested sample rate
                guard let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(sampleRate),
                    channels: AVAudioChannelCount(channels),
                    interleaved: true
                ) else {
                    result(FlutterError(code: "FORMAT_ERROR",
                                        message: "Failed to create target format", details: nil))
                    return
                }

                converter = AVAudioConverter(from: hwInt16Format, to: targetFormat)
                NSLog("BmcAudioPlugin: ⚠️ Hardware rate (\(hwFormat.sampleRate)) != requested (\(sampleRate)). Converter active — XOR decrypt may not work!")
                actualSampleRate = Double(sampleRate)
            }

            // 7. Install tap on input node
            let bufferSize: AVAudioFrameCount = 1024
            var chunkCount: Int64 = 0

            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: outputFormat) {
                [weak self] (buffer, time) in
                guard let self = self, self.isCapturing else { return }

                chunkCount += 1

                // Get the Int16 data from the buffer
                guard let int16Data = buffer.int16ChannelData else {
                    // Fallback: if Int16 channel data not available, try float and convert
                    NSLog("BmcAudioPlugin: No int16 channel data available")
                    return
                }

                let frameCount = Int(buffer.frameLength)
                let channelCount = Int(buffer.format.channelCount)
                let byteCount = frameCount * channelCount * 2 // 2 bytes per Int16 sample

                // Create Data from Int16 samples (already in LE on ARM/x86)
                let data = Data(bytes: int16Data[0], count: byteCount)
                let flutterData = FlutterStandardTypedData(bytes: data)

                if chunkCount <= 5 || chunkCount % 100 == 0 {
                    NSLog("BmcAudioPlugin: Chunk #\(chunkCount): \(byteCount) bytes, frames=\(frameCount)")
                }

                // Send to Dart on main thread
                DispatchQueue.main.async {
                    self.eventSink?(flutterData)
                }
            }

            // 8. Start engine
            try engine.start()
            audioEngine = engine
            isCapturing = true

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

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false,
            options: .notifyOthersOnDeactivation)

        NSLog("BmcAudioPlugin: Capture stopped")
    }

    // MARK: - Cleanup
    deinit {
        stopCapture()
    }
}
