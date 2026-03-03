package com.bmc.audio.bmc_audio

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.*
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.nio.ByteBuffer

/**
 * BmcAudioPlugin — Native Android audio capture with USB device support.
 *
 * Supports two capture modes:
 * 1. AudioRecord (for devices recognized by Android audio HAL)
 * 2. Direct USB isochronous capture (for composite USB devices)
 */
class BmcAudioPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "BmcAudioPlugin"
        private const val METHOD_CHANNEL = "bmc_audio"
        private const val EVENT_CHANNEL = "bmc_audio/audio_stream"
        private const val ACTION_USB_PERMISSION = "com.bmc.audio.USB_PERMISSION"

        // USB Audio Class constants
        private const val USB_CLASS_AUDIO = 1
        private const val USB_SUBCLASS_AUDIOSTREAMING = 2

        init {
            System.loadLibrary("bmc_usb_audio")
        }
    }

    // Native JNI methods (implemented in usb_audio_iso.c)
    private external fun nativeClaimInterface(fd: Int, interfaceNum: Int): Int
    private external fun nativeReleaseInterface(fd: Int, interfaceNum: Int): Int
    private external fun nativeSetInterface(fd: Int, interfaceNum: Int, altSetting: Int): Int
    private external fun nativeIsoRead(fd: Int, endpoint: Int, maxPacket: Int, numPackets: Int): ByteArray?

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var applicationContext: Context? = null

    // Audio capture state
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    private var isCapturing = false
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // USB direct capture
    private var usbConnection: UsbDeviceConnection? = null
    private var usbCaptureThread: Thread? = null
    private var isUsbCapturing = false

    // USB permission
    private var pendingPermissionResult: Result? = null
    private var usbPermissionReceiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopCapture()
        stopUsbCapture()
        unregisterUsbReceiver()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        applicationContext = null
    }

    // ── EventChannel ────────────────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ── MethodCallHandler ───────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${Build.VERSION.RELEASE}")
            "listDevices" -> result.success(listAudioDevices())
            "listUsbDevices" -> result.success(listUsbDevices())
            "requestUsbPermission" -> {
                val vid = call.argument<Int>("vendorId")
                val pid = call.argument<Int>("productId")
                requestUsbPermission(vid, pid, result)
            }
            "startCapture" -> {
                val deviceId = call.argument<Int>("deviceId")
                val sampleRate = call.argument<Int>("sampleRate") ?: 16000
                val channels = call.argument<Int>("channels") ?: 1
                startCapture(deviceId, sampleRate, channels, result)
            }
            "startUsbCapture" -> {
                val vid = call.argument<Int>("vendorId")
                val pid = call.argument<Int>("productId")
                val sampleRate = call.argument<Int>("sampleRate") ?: 16000
                val channels = call.argument<Int>("channels") ?: 1
                startUsbCapture(vid, pid, sampleRate, channels, result)
            }
            "stopCapture" -> {
                stopCapture()
                stopUsbCapture()
                result.success(null)
            }
            "isCapturing" -> result.success(isCapturing || isUsbCapturing)
            else -> result.notImplemented()
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // Audio Device Enumeration (AudioManager)
    // ══════════════════════════════════════════════════════════════════════

    private fun listAudioDevices(): List<Map<String, Any>> {
        val audioManager = applicationContext?.getSystemService(Context.AUDIO_SERVICE)
                as? AudioManager ?: return emptyList()

        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        return devices.map { device ->
            mutableMapOf<String, Any>(
                "id" to device.id,
                "name" to getDeviceName(device),
                "type" to device.type,
                "typeName" to getDeviceTypeName(device.type),
                "isUsb" to isUsbAudioDevice(device),
                "isSource" to device.isSource,
            ).also { info ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    info["productName"] = device.productName?.toString() ?: ""
                }
            }
        }.also {
            Log.i(TAG, "AudioManager: ${it.size} input devices")
        }
    }

    private fun getDeviceName(device: AudioDeviceInfo): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            device.productName?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        }
        return getDeviceTypeName(device.type)
    }

    private fun getDeviceTypeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Built-in Microphone"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "USB Audio Device"
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB Accessory"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "USB Headset"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired Headset"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth SCO"
        AudioDeviceInfo.TYPE_TELEPHONY -> "Telephony"
        else -> "Audio Device (type=$type)"
    }

    private fun isUsbAudioDevice(device: AudioDeviceInfo): Boolean =
        device.type in listOf(
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_ACCESSORY,
            AudioDeviceInfo.TYPE_USB_HEADSET
        )

    // ══════════════════════════════════════════════════════════════════════
    // USB Device Enumeration (UsbManager — hardware level)
    // ══════════════════════════════════════════════════════════════════════

    private fun listUsbDevices(): List<Map<String, Any>> {
        val usbManager = applicationContext?.getSystemService(Context.USB_SERVICE)
                as? UsbManager ?: return emptyList()

        return usbManager.deviceList.map { (name, device) ->
            val isAudio = (0 until device.interfaceCount).any {
                device.getInterface(it).interfaceClass == USB_CLASS_AUDIO
            }

            val interfaces = (0 until device.interfaceCount).map { i ->
                val intf = device.getInterface(i)
                mapOf(
                    "id" to intf.id,
                    "interfaceClass" to intf.interfaceClass,
                    "interfaceSubclass" to intf.interfaceSubclass,
                    "endpointCount" to intf.endpointCount,
                    "name" to (intf.name ?: ""),
                )
            }

            mutableMapOf<String, Any>(
                "name" to name,
                "vendorId" to device.vendorId,
                "productId" to device.productId,
                "deviceClass" to device.deviceClass,
                "interfaceCount" to device.interfaceCount,
                "manufacturerName" to (device.manufacturerName ?: ""),
                "productName" to (device.productName ?: ""),
                "hasPermission" to usbManager.hasPermission(device),
                "isAudioClass" to isAudio,
                "interfaces" to interfaces,
            )
        }.also {
            Log.i(TAG, "UsbManager: ${it.size} USB devices")
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // USB Permission
    // ══════════════════════════════════════════════════════════════════════

    private fun requestUsbPermission(vendorId: Int?, productId: Int?, result: Result) {
        val context = applicationContext ?: run {
            result.error("NO_CONTEXT", "No application context", null)
            return
        }

        val usbManager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: run {
            result.error("NO_USB", "UsbManager not available", null)
            return
        }

        val device = findUsbDevice(usbManager, vendorId, productId) ?: run {
            result.error("NOT_FOUND", "USB device not found", null)
            return
        }

        if (usbManager.hasPermission(device)) {
            result.success(mapOf("granted" to true, "productName" to (device.productName ?: "")))
            return
        }

        pendingPermissionResult = result
        unregisterUsbReceiver()

        usbPermissionReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action != ACTION_USB_PERMISSION) return

                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                val dev = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                }

                Log.i(TAG, "USB permission: granted=$granted device=${dev?.productName}")
                mainHandler.post {
                    pendingPermissionResult?.success(mapOf(
                        "granted" to granted,
                        "productName" to (dev?.productName ?: ""),
                    ))
                    pendingPermissionResult = null
                }
                unregisterUsbReceiver()
            }
        }

        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(usbPermissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(usbPermissionReceiver, filter)
        }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        else PendingIntent.FLAG_UPDATE_CURRENT

        usbManager.requestPermission(device,
            PendingIntent.getBroadcast(context, 0, Intent(ACTION_USB_PERMISSION), flags))
    }

    private fun findUsbDevice(usbManager: UsbManager, vid: Int?, pid: Int?): UsbDevice? {
        for ((_, device) in usbManager.deviceList) {
            if (vid != null && pid != null) {
                if (device.vendorId == vid && device.productId == pid) return device
            } else {
                // Find first audio-class device
                if ((0 until device.interfaceCount).any {
                    device.getInterface(it).interfaceClass == USB_CLASS_AUDIO
                }) return device
            }
        }
        return null
    }

    private fun unregisterUsbReceiver() {
        try { usbPermissionReceiver?.let { applicationContext?.unregisterReceiver(it) } }
        catch (_: Exception) {}
        usbPermissionReceiver = null
    }

    // ══════════════════════════════════════════════════════════════════════
    // Direct USB Isochronous Audio Capture
    // ══════════════════════════════════════════════════════════════════════

    /**
     * Start capturing audio directly from USB audio endpoint.
     * Uses bulkTransfer() which is more reliable than UsbRequest for
     * isochronous endpoints on many Android devices.
     */
    private fun startUsbCapture(
        vendorId: Int?, productId: Int?,
        sampleRate: Int, channels: Int,
        result: Result
    ) {
        if (isUsbCapturing) {
            result.error("ALREADY_CAPTURING", "USB capture already running", null)
            return
        }

        val context = applicationContext ?: run {
            result.error("NO_CONTEXT", "No context", null)
            return
        }

        val usbManager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: run {
            result.error("NO_USB", "UsbManager not available", null)
            return
        }

        val device = findUsbDevice(usbManager, vendorId, productId) ?: run {
            result.error("NOT_FOUND", "USB device not found", null)
            return
        }

        if (!usbManager.hasPermission(device)) {
            result.error("NO_PERMISSION", "USB permission not granted", null)
            return
        }

        try {
            // Find the audio streaming interface and endpoint
            val audioInfo = findAudioStreamingEndpoint(device)
            if (audioInfo == null) {
                result.error("NO_AUDIO_EP",
                    "No audio streaming endpoint found. " +
                    "Device has ${device.interfaceCount} interfaces.", null)
                return
            }

            val (audioInterface, audioEndpoint, altSetting) = audioInfo
            Log.i(TAG, "Audio endpoint found:")
            Log.i(TAG, "  interface id=${audioInterface.id}, altSetting=$altSetting")
            Log.i(TAG, "  endpoint addr=0x${"%02X".format(audioEndpoint.address)}")
            Log.i(TAG, "  type=${endpointTypeName(audioEndpoint.type)}, dir=${if (audioEndpoint.direction == UsbConstants.USB_DIR_IN) "IN" else "OUT"}")
            Log.i(TAG, "  maxPacket=${audioEndpoint.maxPacketSize}, interval=${audioEndpoint.interval}")

            // Open USB connection
            val connection = usbManager.openDevice(device)
            if (connection == null) {
                result.error("OPEN_FAILED", "Failed to open USB device", null)
                return
            }
            Log.i(TAG, "USB device opened, fd=${connection.fileDescriptor}")

            // Claim the audio streaming interface
            val claimed = connection.claimInterface(audioInterface, true)
            Log.i(TAG, "claimInterface(${audioInterface.id}): $claimed")
            if (!claimed) {
                connection.close()
                result.error("CLAIM_FAILED", "Failed to claim audio interface", null)
                return
            }

            // SET_INTERFACE control transfer to activate streaming alt setting
            val setAltResult = connection.controlTransfer(
                0x01, // USB_DIR_OUT | USB_TYPE_STANDARD | USB_RECIP_INTERFACE
                0x0B, // SET_INTERFACE
                altSetting, // wValue = alternate setting
                audioInterface.id, // wIndex = interface number
                null, 0, 1000
            )
            Log.i(TAG, "SET_INTERFACE(alt=$altSetting, intf=${audioInterface.id}): $setAltResult")

            usbConnection = connection
            isUsbCapturing = true

            // Get file descriptor for native isochronous reads
            val fd = connection.fileDescriptor
            val maxPacketSize = audioEndpoint.maxPacketSize
            val endpointAddr = audioEndpoint.address
            val intfNum = audioInterface.id

            // Claim interface via native ioctl (more reliable than Java API for isoc)
            val nativeClaim = nativeClaimInterface(fd, intfNum)
            Log.i(TAG, "nativeClaimInterface($intfNum): $nativeClaim")

            // Set alternate setting via native ioctl
            if (altSetting > 0) {
                val nativeSetAlt = nativeSetInterface(fd, intfNum, altSetting)
                Log.i(TAG, "nativeSetInterface(intf=$intfNum, alt=$altSetting): $nativeSetAlt")
            }

            // Number of isoc packets per URB
            // For 16kHz 16-bit mono: each packet ~32 bytes (1ms), read ~8ms at a time
            val numPackets = 8

            usbCaptureThread = Thread({
                Log.i(TAG, "=== USB ISO capture thread started ===")
                Log.i(TAG, "  fd=$fd, endpoint=0x${"${"%02X".format(endpointAddr)}"}")
                Log.i(TAG, "  maxPacket=$maxPacketSize, numPackets=$numPackets")

                var chunkCount = 0L
                var errorCount = 0
                var totalBytes = 0L

                try {
                    while (isUsbCapturing) {
                        val data = nativeIsoRead(fd, endpointAddr, maxPacketSize, numPackets)

                        if (data != null && data.isNotEmpty()) {
                            chunkCount++
                            totalBytes += data.size
                            errorCount = 0

                            mainHandler.post {
                                eventSink?.success(data)
                            }

                            if (chunkCount <= 5 || chunkCount % 500 == 0L) {
                                Log.i(TAG, "ISO chunk #$chunkCount: ${data.size} bytes (total=$totalBytes)")
                            }
                        } else {
                            errorCount++
                            if (errorCount <= 5) {
                                Log.e(TAG, "nativeIsoRead returned ${if (data == null) "null" else "empty"} (#$errorCount)")
                            }
                            if (errorCount > 50) {
                                Log.e(TAG, "Too many ISO read errors, stopping")
                                mainHandler.post {
                                    eventSink?.error("USB_ISO_FAIL",
                                        "Isochronous read failed after $errorCount attempts", null)
                                }
                                break
                            }
                            Thread.sleep(1)
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "ISO capture exception: ${e.message}", e)
                    mainHandler.post {
                        eventSink?.error("USB_EXCEPTION", "${e.message}", null)
                    }
                } finally {
                    // Release interface
                    nativeReleaseInterface(fd, intfNum)
                    Log.i(TAG, "=== ISO capture ended: $chunkCount chunks, $totalBytes bytes ===")
                    isUsbCapturing = false
                }
            }, "BmcUsbIsoCapture")
            usbCaptureThread?.start()

            Log.i(TAG, "USB ISO capture started for ${device.productName}")
            result.success(mapOf(
                "endpoint" to audioEndpoint.address,
                "maxPacketSize" to maxPacketSize,
                "interfaceId" to audioInterface.id,
                "endpointType" to endpointTypeName(audioEndpoint.type),
                "fd" to fd,
            ))

        } catch (e: Exception) {
            Log.e(TAG, "startUsbCapture failed: ${e.message}", e)
            result.error("USB_ERROR", "USB capture failed: ${e.message}", null)
        }
    }

    private fun endpointTypeName(type: Int): String = when (type) {
        UsbConstants.USB_ENDPOINT_XFER_CONTROL -> "CONTROL"
        UsbConstants.USB_ENDPOINT_XFER_ISOC -> "ISOC"
        UsbConstants.USB_ENDPOINT_XFER_BULK -> "BULK"
        UsbConstants.USB_ENDPOINT_XFER_INT -> "INT"
        else -> "UNKNOWN($type)"
    }

    /**
     * Find the audio streaming isochronous IN endpoint.
     * Scans all interfaces for USB Audio Class (class=1, subclass=2)
     * with an isochronous IN endpoint.
     */
    private fun findAudioStreamingEndpoint(device: UsbDevice): Triple<UsbInterface, UsbEndpoint, Int>? {
        Log.i(TAG, "Scanning ${device.interfaceCount} interfaces for audio streaming...")

        for (i in 0 until device.interfaceCount) {
            val intf = device.getInterface(i)

            // Look for Audio Streaming interface (class=1, subclass=2)
            if (intf.interfaceClass == USB_CLASS_AUDIO &&
                intf.interfaceSubclass == USB_SUBCLASS_AUDIOSTREAMING) {

                Log.i(TAG, "  Interface $i: AudioStreaming, " +
                        "altSetting=${intf.alternateSetting}, " +
                        "endpoints=${intf.endpointCount}")

                // Find isochronous IN endpoint
                for (j in 0 until intf.endpointCount) {
                    val ep = intf.getEndpoint(j)

                    if (ep.type == UsbConstants.USB_ENDPOINT_XFER_ISOC &&
                        ep.direction == UsbConstants.USB_DIR_IN) {

                        Log.i(TAG, "    Found ISOC IN endpoint: " +
                                "address=0x${"%02X".format(ep.address)}, " +
                                "maxPacket=${ep.maxPacketSize}, " +
                                "interval=${ep.interval}")

                        return Triple(intf, ep, intf.alternateSetting)
                    }
                }
            }
        }

        Log.w(TAG, "No audio streaming isochronous IN endpoint found")
        return null
    }

    private fun stopUsbCapture() {
        isUsbCapturing = false
        try { usbCaptureThread?.join(3000) } catch (_: Exception) {}
        usbCaptureThread = null

        try {
            usbConnection?.releaseInterface(
                usbConnection?.let { _ ->
                    // Release will happen on close
                    null
                } ?: return
            )
        } catch (_: Exception) {}

        try { usbConnection?.close() } catch (_: Exception) {}
        usbConnection = null

        Log.i(TAG, "USB capture stopped")
    }

    // ══════════════════════════════════════════════════════════════════════
    // AudioRecord Capture (for standard audio devices)
    // ══════════════════════════════════════════════════════════════════════

    private fun startCapture(deviceId: Int?, sampleRate: Int, channels: Int, result: Result) {
        if (isCapturing) {
            result.error("ALREADY_CAPTURING", "Already capturing", null)
            return
        }

        try {
            val channelConfig = if (channels == 1)
                AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
            val encoding = AudioFormat.ENCODING_PCM_16BIT
            val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)
            if (minBuf <= 0) {
                result.error("BUFFER_ERROR", "Invalid buffer size", null)
                return
            }

            val bufferSize = maxOf(minBuf * 4, sampleRate * channels * 2)

            audioRecord = AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelConfig)
                    .setEncoding(encoding)
                    .build())
                .setBufferSizeInBytes(bufferSize)
                .build()

            if (deviceId != null) {
                val am = applicationContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                am?.getDevices(AudioManager.GET_DEVICES_INPUTS)
                    ?.find { it.id == deviceId }
                    ?.let { audioRecord?.setPreferredDevice(it) }
            }

            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                result.error("INIT_FAILED", "AudioRecord init failed", null)
                audioRecord?.release()
                audioRecord = null
                return
            }

            audioRecord?.startRecording()
            isCapturing = true

            captureThread = Thread({
                val buf = ByteArray(sampleRate * channels * 2 / 50)
                while (isCapturing) {
                    val n = audioRecord?.read(buf, 0, buf.size) ?: -1
                    if (n > 0) {
                        val data = buf.copyOf(n)
                        mainHandler.post { eventSink?.success(data) }
                    } else if (n < 0) break
                }
            }, "BmcAudioCapture")
            captureThread?.start()

            result.success(null)
        } catch (e: SecurityException) {
            result.error("PERMISSION", "Mic permission denied: ${e.message}", null)
        } catch (e: Exception) {
            result.error("ERROR", "Capture failed: ${e.message}", null)
        }
    }

    private fun stopCapture() {
        isCapturing = false
        try { captureThread?.join(2000) } catch (_: Exception) {}
        captureThread = null
        try { audioRecord?.stop() } catch (_: Exception) {}
        try { audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
    }
}
