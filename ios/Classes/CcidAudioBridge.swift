import Foundation
import CryptoTokenKit

/// CCID Audio Bridge — Streams encrypted PCM16LE audio from S-USB device
/// over CryptoTokenKit smart card interface, bypassing CoreAudio's lossy
/// Float32 pipeline.
///
/// Uses the same CLA=0xB0 proprietary APDU protocol as CcidTransportClient.
/// Audio-specific INS codes:
///   0xA0 — AUDIO_CONTROL (start/stop streaming + encryption toggle)
///   0xA2 — AUDIO_READ    (poll encrypted PCM data from ring buffer)
///   0xA4 — AUDIO_STATUS  (get buffer status, sample rate, encrypt state)
///
/// Throughput: Audio = 32 KB/s @ 16kHz/16-bit/mono.
/// CCID round-trip ~5-10ms → 100-200 polls/s × 250 bytes = 25-50 KB/s.
/// Tight polling loop (no timer delay) is required to keep up.
class CcidAudioBridge {

    // MARK: - Constants

    private static let customCLA: UInt8 = 0xB0

    private static let insAudioControl: UInt8 = 0xA0
    private static let insAudioRead: UInt8    = 0xA2
    private static let insAudioStatus: UInt8  = 0xA4

    private static let swSuccess: UInt16 = 0x9000

    /// Max APDU response data (FW dwMaxCCIDMessageLength=271 - header - SW)
    private static let maxPayload: Int = 250

    private static let tag = "CcidAudioBridge"

    // MARK: - State

    private var smartCard: TKSmartCard?
    private var sessionActive = false
    private var streaming = false

    /// Background polling thread
    private var pollThread: Thread?
    private let pollQueue = DispatchQueue(label: "com.bmc.audio.ccid", qos: .userInitiated)

    /// Callback for received audio data
    var onAudioData: ((Data) -> Void)?

    // MARK: - Connection

    /// Find S-USB smart card slot and begin exclusive session.
    func connect() -> Bool {
        guard let manager = TKSmartCardSlotManager.default else {
            NSLog("[\(CcidAudioBridge.tag)] TKSmartCardSlotManager not available")
            return false
        }

        let slotNames = manager.slotNames
        NSLog("[\(CcidAudioBridge.tag)] Available slots: \(slotNames)")

        for slotName in slotNames {
            let semaphore = DispatchSemaphore(value: 0)
            var foundSlot: TKSmartCardSlot?

            manager.getSlot(withName: slotName) { slot in
                foundSlot = slot
                semaphore.signal()
            }
            semaphore.wait()

            guard let slot = foundSlot,
                  let card = slot.makeSmartCard() else { continue }

            smartCard = card
            card.useExtendedLength = false
            card.useCommandChaining = false

            let sessionSem = DispatchSemaphore(value: 0)
            var ok = false
            card.beginSession { success, error in
                if let error = error {
                    NSLog("[\(CcidAudioBridge.tag)] beginSession error: \(error)")
                }
                ok = success
                sessionSem.signal()
            }
            sessionSem.wait()

            if ok {
                sessionActive = true
                NSLog("[\(CcidAudioBridge.tag)] Connected to slot: \(slotName)")
                return true
            }
        }

        return false
    }

    func disconnect() {
        stopStream()
        if sessionActive {
            smartCard?.endSession()
            sessionActive = false
        }
        smartCard = nil
    }

    var isConnected: Bool { sessionActive }

    // MARK: - APDU Transmit

    private func transmit(_ apdu: Data) -> (Data, UInt16)? {
        guard let card = smartCard, sessionActive else { return nil }

        let sem = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        card.transmit(apdu) { response, error in
            resultData = response
            resultError = error
            sem.signal()
        }
        sem.wait()

        if let error = resultError {
            NSLog("[\(CcidAudioBridge.tag)] transmit error: \(error)")
            return nil
        }

        guard let response = resultData, response.count >= 2 else {
            return nil
        }

        let sw1 = UInt16(response[response.count - 2])
        let sw2 = UInt16(response[response.count - 1])
        let sw = (sw1 << 8) | sw2
        let data = response.subdata(in: 0..<(response.count - 2))
        return (data, sw)
    }

    private func buildAPDU(ins: UInt8, p1: UInt8, p2: UInt8 = 0x00,
                           le: UInt8? = nil) -> Data {
        var apdu = Data([CcidAudioBridge.customCLA, ins, p1, p2])
        if let le = le {
            apdu.append(le)
        }
        return apdu
    }

    // MARK: - Audio Control

    func getStatus() -> (avail: Int, sampleRate: Int, encrypted: Bool,
                         streaming: Bool, ringSize: Int)? {
        let apdu = buildAPDU(ins: CcidAudioBridge.insAudioStatus, p1: 0x00, le: 8)
        guard let (data, sw) = transmit(apdu),
              sw == CcidAudioBridge.swSuccess,
              data.count >= 8 else { return nil }

        let avail = Int(data[0]) | (Int(data[1]) << 8)
        let rate = Int(data[2]) | (Int(data[3]) << 8)
        let enc = data[4] != 0
        let active = data[5] != 0
        let ringSize = Int(data[6]) | (Int(data[7]) << 8)

        return (avail, rate, enc, active, ringSize)
    }

    func startStream() -> Bool {
        let apdu = buildAPDU(ins: CcidAudioBridge.insAudioControl, p1: 0x01)
        guard let (_, sw) = transmit(apdu),
              sw == CcidAudioBridge.swSuccess else {
            NSLog("[\(CcidAudioBridge.tag)] startStream failed")
            return false
        }

        streaming = true
        NSLog("[\(CcidAudioBridge.tag)] Stream started")
        return true
    }

    func stopStream() {
        if streaming {
            streaming = false  // Signal tight loop to exit
            // Wait for poll thread to finish
            pollThread?.cancel()
            Thread.sleep(forTimeInterval: 0.05)
            pollThread = nil

            let apdu = buildAPDU(ins: CcidAudioBridge.insAudioControl, p1: 0x00)
            _ = transmit(apdu)
            NSLog("[\(CcidAudioBridge.tag)] Stream stopped")
        }
    }

    // MARK: - Audio Polling (tight loop)

    /// Poll one chunk of encrypted audio data from the ring buffer.
    func pollAudio() -> Data? {
        guard streaming else { return nil }

        let apdu = buildAPDU(ins: CcidAudioBridge.insAudioRead, p1: 0x00,
                             le: UInt8(CcidAudioBridge.maxPayload & 0xFF))
        guard let (data, sw) = transmit(apdu),
              sw == CcidAudioBridge.swSuccess else { return nil }

        return data
    }

    /// Start adaptive polling on background queue.
    ///
    /// Reads back-to-back when data is available (maximizing throughput).
    /// Brief 2ms sleep only when ring buffer is empty (saving CPU).
    /// Earlier tight loop achieved 31.1 KB/s — sufficient for 32 KB/s audio.
    func startPolling(intervalMs: Int = 0) {
        streaming = true
        var totalBytes: Int64 = 0
        let startTime = CFAbsoluteTimeGetCurrent()

        pollQueue.async { [weak self] in
            NSLog("[\(CcidAudioBridge.tag)] Adaptive polling loop started")

            while let self = self, self.streaming {
                if let data = self.pollAudio(), !data.isEmpty {
                    totalBytes += Int64(data.count)
                    self.onAudioData?(data)
                    // No sleep — read again immediately to keep up
                } else {
                    // Ring empty — brief sleep to avoid CPU spin
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let kbps = elapsed > 0 ? Double(totalBytes) / elapsed / 1024.0 : 0
            NSLog("[\(CcidAudioBridge.tag)] Polling stopped: \(totalBytes) bytes in \(String(format: "%.1f", elapsed))s = \(String(format: "%.1f", kbps)) KB/s")
        }
    }

    /// Stop polling (for API compat, calls stopStream internally).
    func stopPolling() {
        // streaming = false is set in stopStream()
    }
}
