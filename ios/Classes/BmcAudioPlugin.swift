import Flutter
import UIKit
import AVFoundation

/// BmcAudioPlugin — Native iOS audio capture with USB device support.
///
/// Two capture modes:
/// 1. AVAudioEngine (standard): Goes through CoreAudio
/// 2. USB Direct (IOKit via BmcUsbHelper): Reads raw USB isochronous data
public class BmcAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    // Audio engine (standard capture)
    private var audioEngine: AVAudioEngine?
    private var isCapturing = false

    // Capture parameters
    private var targetSampleRate: Double = 16000
    private var targetChannels: UInt32 = 1

    // MARK: - Plugin Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = BmcAudioPlugin()

        let methodChannel = FlutterMethodChannel(
            name: "bmc_audio",
            binaryMessenger: registrar.messenger()
        )
        instance.methodChannel = methodChannel
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: "bmc_audio/audio_stream",
            binaryMessenger: registrar.messenger()
        )
        instance.eventChannel = eventChannel
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

    // MARK: - MethodCallHandler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)

        case "listDevices":
            result(listAudioDevices())

        case "listUsbDevices":
            // Use IOKit-based USB enumeration via ObjC helper
            let devices = BmcUsbHelper.listUsbDevices()
            result(devices)

        case "requestUsbPermission":
            let args = call.arguments as? [String: Any]
            let vid = args?["vendorId"] as? Int ?? 0
            let pid = args?["productId"] as? Int ?? 0
            let found = BmcUsbHelper.findDevice(withVendorId: UInt16(vid),
                                                 productId: UInt16(pid))
            result(["granted": found, "productName": found ? "S-USB AIO" : ""])

        case "startCapture":
            let args = call.arguments as? [String: Any]
            let sampleRate = args?["sampleRate"] as? Int ?? 16000
            let channels = args?["channels"] as? Int ?? 1
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
        var devices = [[String: Any]]()

        // Activate session to discover USB audio devices
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            NSLog("BmcAudioPlugin: Failed to activate session: \(error)")
        }

        guard let inputs = session.availableInputs else { return devices }

        for (index, port) in inputs.enumerated() {
            let isUsb = port.portType == .usbAudio
            devices.append([
                "id": index,
                "name": port.portName,
                "typeName": portTypeName(port.portType),
                "isUsb": isUsb,
                "productName": port.portName,
                "isSource": true,
            ])
        }

        // Also check if USB devices are available via IOKit
        let usbDevices = BmcUsbHelper.listUsbDevices() as? [[String: Any]] ?? []
        for usbDev in usbDevices {
            let vid = usbDev["vendorId"] as? Int ?? 0
            // Add BMC USB devices that aren't already in the list
            if vid == 0x1fc9 {
                let name = usbDev["productName"] as? String ?? "BMC USB"
                let alreadyListed = devices.contains { ($0["name"] as? String ?? "").contains("AIO") }
                if !alreadyListed {
                    devices.append([
                        "id": devices.count,
                        "name": name,
                        "typeName": "USB Audio (Direct)",
                        "isUsb": true,
                        "productName": name,
                        "isSource": true,
                        "vendorId": vid,
                        "productId": usbDev["productId"] as? Int ?? 0,
                    ])
                }
            }
        }

        return devices
    }

    private func portTypeName(_ portType: AVAudioSession.Port) -> String {
        switch portType {
        case .builtInMic: return "Built-in Microphone"
        case .usbAudio: return "USB Audio"
        case .headsetMic: return "Headset Microphone"
        case .bluetoothHFP: return "Bluetooth HFP"
        case .bluetoothLE: return "Bluetooth LE"
        default: return portType.rawValue
        }
    }

    // MARK: - USB Direct Capture (IOKit)

    private func startUsbDirectCapture(vid: UInt16, pid: UInt16,
                                       result: @escaping FlutterResult) {
        let sink = self.eventSink

        let captureResult = BmcUsbHelper.startIsocCapture(
            withVendorId: vid,
            productId: pid,
            interfaceNum: 4,        // Audio Streaming interface
            altSetting: 1,          // Active streaming alt setting
            dataCallback: { [weak self] data in
                DispatchQueue.main.async {
                    sink?(FlutterStandardTypedData(bytes: data))
                }
            },
            errorCallback: { error in
                NSLog("BmcAudioPlugin: USB Direct error: \(error)")
                DispatchQueue.main.async {
                    sink?(FlutterError(code: "USB_ERROR",
                                       message: error, details: nil))
                }
            }
        )

        if let info = captureResult as? [String: Any] {
            NSLog("BmcAudioPlugin: ✓ USB Direct capture started: \(info)")
            result(info)
        } else {
            result(FlutterError(code: "USB_FAILED",
                                message: "Failed to start USB capture",
                                details: nil))
        }
    }

    // MARK: - Standard Audio Capture (AVAudioEngine fallback)

    private func startCapture(deviceId: Int?, sampleRate: Int,
                              channels: Int, result: @escaping FlutterResult) {
        if isCapturing {
            result(FlutterError(code: "ALREADY_CAPTURING",
                                message: "Already capturing", details: nil))
            return
        }

        targetSampleRate = Double(sampleRate)
        targetChannels = UInt32(channels)

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord,
                                    mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(targetSampleRate)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)

            if let deviceId = deviceId,
               let inputs = session.availableInputs,
               deviceId >= 0 && deviceId < inputs.count {
                try session.setPreferredInput(inputs[deviceId])
            }

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)
            let captureRate = hwFormat.sampleRate
            let captureChannels = min(hwFormat.channelCount, targetChannels)
            let bufferSize = AVAudioFrameCount(captureRate * 0.02)

            guard let pcm16Format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: captureRate,
                channels: captureChannels, interleaved: true
            ) else {
                result(FlutterError(code: "FORMAT_ERROR",
                                    message: "Cannot create format", details: nil))
                return
            }

            let converter = hwFormat.commonFormat != .pcmFormatInt16
                ? AVAudioConverter(from: hwFormat, to: pcm16Format) : nil

            inputNode.installTap(onBus: 0, bufferSize: bufferSize,
                                 format: hwFormat) { [weak self] (buffer, _) in
                guard let self = self, self.isCapturing else { return }

                let pcmData: Data
                if let conv = converter {
                    guard let d = self.convertBuffer(buffer, converter: conv, targetFormat: pcm16Format) else { return }
                    pcmData = d
                } else {
                    guard let ch = buffer.int16ChannelData else { return }
                    pcmData = Data(bytes: ch[0], count: Int(buffer.frameLength) * Int(captureChannels) * 2)
                }

                DispatchQueue.main.async {
                    self.eventSink?(FlutterStandardTypedData(bytes: pcmData))
                }
            }

            engine.prepare()
            try engine.start()
            self.audioEngine = engine
            self.isCapturing = true
            result(nil)
        } catch {
            result(FlutterError(code: "CAPTURE_ERROR",
                                message: error.localizedDescription, details: nil))
        }
    }

    private func convertBuffer(_ input: AVAudioPCMBuffer,
                               converter: AVAudioConverter,
                               targetFormat: AVAudioFormat) -> Data? {
        let outFrames = input.frameLength
        guard outFrames > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames)
        else { return nil }

        var consumed = false
        converter.convert(to: output, error: nil) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData; consumed = true; return input
        }

        guard output.frameLength > 0, let data = output.int16ChannelData else { return nil }
        return Data(bytes: data[0], count: Int(output.frameLength) * Int(targetFormat.channelCount) * 2)
    }

    // MARK: - Stop

    private func stopCapture() {
        if isCapturing {
            isCapturing = false
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine = nil

            do {
                try AVAudioSession.sharedInstance().setActive(false,
                    options: .notifyOthersOnDeactivation)
            } catch {}
        }
    }

    // MARK: - Cleanup

    public func detachFromEngine(for registrar: any FlutterPluginRegistrar) {
        stopCapture()
        BmcUsbHelper.stopIsocCapture()
        methodChannel?.setMethodCallHandler(nil)
        eventChannel?.setStreamHandler(nil)
    }
}
