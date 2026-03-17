import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:bmc_audio/bmc_audio.dart';

void main() {
  runApp(const BmcAudioExampleApp());
}

class BmcAudioExampleApp extends StatelessWidget {
  const BmcAudioExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BMC Audio Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E88E5),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const AudioCaptureScreen(),
    );
  }
}

class AudioCaptureScreen extends StatefulWidget {
  const AudioCaptureScreen({super.key});

  @override
  State<AudioCaptureScreen> createState() => _AudioCaptureScreenState();
}

class _AudioCaptureScreenState extends State<AudioCaptureScreen> {
  final BmcAudioDecoder _decoder = BmcAudioDecoder();

  // State
  bool _hasPermission = false;
  List<BmcAudioDevice> _devices = [];
  BmcAudioDevice? _selectedDevice;
  bool _isCapturing = false;
  bool _decryptEnabled = true;
  bool _userOverrideDecrypt = false; // true when user manually toggles XOR

  // Debug log (shown on screen since USB is occupied by device)
  final List<String> _debugLog = [];

  // Audio stats
  int _totalSamples = 0;
  int _totalBytes = 0;
  double _peakAmplitude = 0.0;
  double _rmsLevel = 0.0;
  final List<double> _waveformData = [];
  static const int _maxWaveformPoints = 200;

  // WAV recording buffer
  final List<Uint8List> _wavBuffer = [];
  int _wavBufferBytes = 0;
  static const int _maxWavSeconds = 60;
  static const int _wavBytesPerSecond = 16000 * 1 * 2; // sampleRate * channels * 2
  String? _savedWavPath;
  bool _isPlaying = false;
  final AudioPlayer _audioPlayer = AudioPlayer();

  // Stream
  StreamSubscription<Uint8List>? _audioSubscription;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  @override
  void dispose() {
    _stopCapture();
    _audioPlayer.dispose();
    _decoder.dispose();
    super.dispose();
  }

  Future<void> _checkPermission() async {
    // On desktop, mic permission is usually granted automatically
    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      setState(() => _hasPermission = true);
      _loadDevices();
      return;
    }

    final status = await Permission.microphone.status;
    if (status.isGranted) {
      setState(() => _hasPermission = true);
      _loadDevices();
    } else {
      final result = await Permission.microphone.request();
      setState(() => _hasPermission = result.isGranted);
      if (result.isGranted) _loadDevices();
    }
  }

  void _log(String msg) {
    final ts = DateTime.now().toString().substring(11, 19);
    setState(() {
      _debugLog.add('[$ts] $msg');
      // Keep last 100 lines
      if (_debugLog.length > 100) _debugLog.removeAt(0);
    });
  }

  Future<void> _loadDevices() async {
    _log('Scanning audio devices...');
    try {
      var devices = await _decoder.listDevices();
      _log('Audio: Found ${devices.length} devices:');
      for (final d in devices) {
        _log('  [${d.id}] "${d.name}" usb=${d.isUsb} bmc=${d.isBmc}');
      }

      // USB hardware scan — Android only (composite device detection)
      if (defaultTargetPlatform == TargetPlatform.android) {
        _log('Scanning USB hardware...');
        try {
          final List<dynamic>? usbDevices = await const MethodChannel('bmc_audio')
              .invokeMethod('listUsbDevices');
          if (usbDevices != null && usbDevices.isNotEmpty) {
            _log('USB Hardware: Found ${usbDevices.length} devices:');
            for (final raw in usbDevices) {
              final map = Map<String, dynamic>.from(raw as Map);
              final vid = (map['vendorId'] as int?)?.toRadixString(16).padLeft(4, '0') ?? '?';
              final pid = (map['productId'] as int?)?.toRadixString(16).padLeft(4, '0') ?? '?';
              _log('  USB: VID=0x$vid PID=0x$pid');
              _log('    product="${map['productName']}" mfr="${map['manufacturerName']}"');
              _log('    isAudio=${map['isAudioClass']} permission=${map['hasPermission']}');
              _log('    interfaces=${map['interfaceCount']}');

              // Auto-request USB permission if audio device without permission
              if (map['isAudioClass'] == true && map['hasPermission'] != true) {
                _log('→ Requesting USB permission...');
                try {
                  final permResult = await const MethodChannel('bmc_audio')
                      .invokeMethod('requestUsbPermission', {
                    'vendorId': map['vendorId'],
                    'productId': map['productId'],
                  });
                  final granted = permResult['granted'] as bool? ?? false;
                  _log('USB permission: ${granted ? "✓ GRANTED" : "✗ DENIED"}');

                  if (granted) {
                    // Re-scan audio devices after permission grant
                    _log('Re-scanning audio devices after permission...');
                    await Future.delayed(const Duration(seconds: 2));
                    final newAudioDevices = await _decoder.listDevices();
                    _log('Audio: Now found ${newAudioDevices.length} devices:');
                    for (final d in newAudioDevices) {
                      _log('  [${d.id}] "${d.name}" usb=${d.isUsb} bmc=${d.isBmc}');
                    }
                    // Update device list
                    devices = newAudioDevices;
                  }
                } catch (e) {
                  _log('USB permission error: $e');
                }
              }
            }
          } else {
            _log('USB Hardware: No USB devices found by UsbManager');
          }
        } catch (e) {
          _log('USB scan error: $e');
        }
      }

      setState(() {
        _devices = devices;
        _selectedDevice = devices.where((d) => d.isBmc).firstOrNull ??
            devices.where((d) => d.isUsb).firstOrNull ??
            (devices.isNotEmpty ? devices.first : null);

        // Auto-set decrypt based on device type (unless user has manually toggled)
        if (!_userOverrideDecrypt && _selectedDevice != null) {
          _decryptEnabled = _selectedDevice!.isBmc;
        }
      });
      if (_selectedDevice != null) {
        _log('Auto-selected: "${_selectedDevice!.name}"');
        _log('Auto-decrypt: ${_decryptEnabled ? "ON (BMC device)" : "OFF (non-BMC device)"}');
      }
    } catch (e) {
      _log('ERROR: $e');
    }
  }

  void _startCapture() {
    if (_isCapturing) return;

    // Wire debug callback so capture pipeline logs appear on screen
    _decoder.onDebug = (msg) => _log('[decoder] $msg');

    _log('Starting capture...');

    try {
      final stream = _decoder.startCapture(
        device: _selectedDevice,
        deviceId: _selectedDevice?.id,
        config: BmcAudioConfig(
          sampleRate: 16000,
          channels: 1,
          // null = auto (BMC → decrypt, non-BMC → raw)
          // explicit true/false when user has manually toggled
          decrypt: _userOverrideDecrypt ? _decryptEnabled : null,
        ),
      );

      _audioSubscription = stream.listen(
        (pcmData) => _processAudioChunk(pcmData),
        onError: (error) {
          _log('Stream error: $error');
          _showSnackBar('Audio error: $error');
        },
      );

      setState(() {
        _isCapturing = true;
        _totalSamples = 0;
        _totalBytes = 0;
        _peakAmplitude = 0;
        _rmsLevel = 0;
        _waveformData.clear();
        _wavBuffer.clear();
        _wavBufferBytes = 0;
        _savedWavPath = null;
      });
    } catch (e) {
      _log('ERROR starting capture: $e');
    }
  }

  Future<void> _stopCapture() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _decoder.stopCapture();
    setState(() => _isCapturing = false);
  }

  void _processAudioChunk(Uint8List pcmData) {
    // Parse PCM16LE samples
    final sampleCount = pcmData.length ~/ 2;
    if (sampleCount == 0) return;

    double sumSquares = 0;
    double peak = 0;

    for (int i = 0; i < sampleCount; i++) {
      // Read 16-bit signed LE sample
      int sample = pcmData[i * 2] | (pcmData[i * 2 + 1] << 8);
      if (sample > 32767) sample -= 65536; // Convert to signed

      final normalized = sample / 32768.0;
      sumSquares += normalized * normalized;
      peak = max(peak, normalized.abs());
    }

    final rms = sqrt(sumSquares / sampleCount);

    // Downsample waveform for display
    final step = max(1, sampleCount ~/ 10);
    for (int i = 0; i < sampleCount; i += step) {
      int sample = pcmData[i * 2] | (pcmData[i * 2 + 1] << 8);
      if (sample > 32767) sample -= 65536;
      _waveformData.add(sample / 32768.0);
      if (_waveformData.length > _maxWaveformPoints) {
        _waveformData.removeAt(0);
      }
    }

    // Buffer for WAV save (max 60 seconds)
    if (_wavBufferBytes < _maxWavSeconds * _wavBytesPerSecond) {
      _wavBuffer.add(Uint8List.fromList(pcmData));
      _wavBufferBytes += pcmData.length;
    }

    setState(() {
      _totalSamples += sampleCount;
      _totalBytes += pcmData.length;
      _peakAmplitude = peak;
      _rmsLevel = rms;
    });
  }

  /// Save buffered audio as WAV file.
  Future<void> _saveWav() async {
    if (_wavBuffer.isEmpty) {
      _showSnackBar('No audio data to save');
      return;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final decrypt = _decryptEnabled ? 'decrypted' : 'raw';
      final path = '${dir.path}/bmc_audio_${decrypt}_$timestamp.wav';

      // Calculate total data size
      final dataSize = _wavBuffer.fold<int>(0, (sum, chunk) => sum + chunk.length);

      // Write WAV file
      final file = File(path);
      final sink = file.openWrite();

      // WAV header (44 bytes)
      final header = ByteData(44);
      // RIFF
      header.setUint8(0, 0x52); // R
      header.setUint8(1, 0x49); // I
      header.setUint8(2, 0x46); // F
      header.setUint8(3, 0x46); // F
      header.setUint32(4, 36 + dataSize, Endian.little); // file size - 8
      // WAVE
      header.setUint8(8, 0x57);  // W
      header.setUint8(9, 0x41);  // A
      header.setUint8(10, 0x56); // V
      header.setUint8(11, 0x45); // E
      // fmt
      header.setUint8(12, 0x66); // f
      header.setUint8(13, 0x6D); // m
      header.setUint8(14, 0x74); // t
      header.setUint8(15, 0x20); // (space)
      header.setUint32(16, 16, Endian.little); // fmt chunk size
      header.setUint16(20, 1, Endian.little);  // PCM format
      header.setUint16(22, 1, Endian.little);  // channels
      header.setUint32(24, 16000, Endian.little); // sample rate
      header.setUint32(28, 16000 * 1 * 2, Endian.little); // byte rate
      header.setUint16(32, 1 * 2, Endian.little); // block align
      header.setUint16(34, 16, Endian.little); // bits per sample
      // data
      header.setUint8(36, 0x64); // d
      header.setUint8(37, 0x61); // a
      header.setUint8(38, 0x74); // t
      header.setUint8(39, 0x61); // a
      header.setUint32(40, dataSize, Endian.little);

      sink.add(header.buffer.asUint8List());

      // Write PCM data
      for (final chunk in _wavBuffer) {
        sink.add(chunk);
      }

      await sink.flush();
      await sink.close();

      final seconds = (dataSize / _wavBytesPerSecond).toStringAsFixed(1);
      _log('✓ WAV saved: ${seconds}s, ${(dataSize / 1024).toStringAsFixed(0)}KB');
      _log('  Path: $path');

      setState(() => _savedWavPath = path);
      _showSnackBar('WAV saved: ${seconds}s ($decrypt)');
    } catch (e) {
      _log('ERROR saving WAV: $e');
      _showSnackBar('Save failed: $e');
    }
  }

  /// Play back the saved WAV file.
  Future<void> _playWav() async {
    if (_savedWavPath == null || !File(_savedWavPath!).existsSync()) {
      _showSnackBar('No saved WAV file');
      return;
    }

    try {
      if (_isPlaying) {
        await _audioPlayer.stop();
        setState(() => _isPlaying = false);
        return;
      }

      _log('Playing: $_savedWavPath');

      // Stop capture before playback to release audio session on iOS
      if (_isCapturing) {
        _log('Stopping capture for playback...');
        await _stopCapture();
      }

      if (defaultTargetPlatform == TargetPlatform.windows) {
        // Windows: open with system default player
        await Process.start('cmd', ['/c', 'start', '', _savedWavPath!]);
        _showSnackBar('Opened in system player');
      } else if (defaultTargetPlatform == TargetPlatform.linux) {
        await Process.start('xdg-open', [_savedWavPath!]);
        _showSnackBar('Opened in system player');
      } else if (defaultTargetPlatform == TargetPlatform.macOS) {
        await Process.start('open', [_savedWavPath!]);
        _showSnackBar('Opened in system player');
      } else {
        // Android/iOS: use just_audio
        await _audioPlayer.setFilePath(_savedWavPath!);
        setState(() => _isPlaying = true);

        _audioPlayer.playerStateStream.listen((state) {
          if (state.processingState == ProcessingState.completed) {
            setState(() => _isPlaying = false);
          }
        });

        await _audioPlayer.play();
      }
    } catch (e) {
      _log('ERROR playing: $e');
      _showSnackBar('Play failed: $e');
      setState(() => _isPlaying = false);
    }
  }

  void _toggleDecrypt() {
    setState(() {
      _decryptEnabled = !_decryptEnabled;
      _userOverrideDecrypt = true; // user explicitly chose
    });

    if (_isCapturing) {
      _decoder.updateConfig(decrypt: _decryptEnabled);
    }
  }

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('BMC Audio Decoder'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadDevices,
            tooltip: 'Refresh Devices',
          ),
        ],
      ),
      body: SafeArea(
        child: _hasPermission ? _buildContent(theme) : _buildPermissionView(theme),
      ),
    );
  }

  Widget _buildPermissionView(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.mic_off, size: 80, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          const Text('Microphone permission required'),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _checkPermission,
            icon: const Icon(Icons.mic),
            label: const Text('Grant Permission'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Device Selection
          _buildDeviceSelector(theme),
          const SizedBox(height: 16),

          // Controls
          _buildControls(theme),
          const SizedBox(height: 16),

          // Waveform
          _buildWaveform(theme),
          const SizedBox(height: 16),

          // Stats
          _buildStats(theme),
          const SizedBox(height: 16),

          // Debug Log
          _buildDebugLog(theme),
        ],
      ),
    );
  }

  Widget _buildDeviceSelector(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.speaker_group, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Audio Device', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            if (_devices.isEmpty)
              const Text('No devices found. Tap refresh to scan.')
            else
              DropdownButtonFormField<BmcAudioDevice>(
                value: _selectedDevice,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: _devices.map((device) {
                  return DropdownMenuItem(
                    value: device,
                    child: Row(
                      children: [
                        Icon(
                          device.isUsb ? Icons.usb : Icons.mic,
                          size: 18,
                          color: device.isBmc
                              ? Colors.green
                              : device.isUsb
                                  ? Colors.blue
                                  : Colors.grey,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            device.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: _isCapturing
                    ? null
                    : (device) {
                        setState(() {
                          _selectedDevice = device;
                          // Auto-update decrypt based on new device (reset manual override)
                          if (device != null) {
                            _userOverrideDecrypt = false;
                            _decryptEnabled = device.isBmc;
                            _log('Device changed: "${device.name}" → decrypt=${_decryptEnabled ? "ON" : "OFF"}');
                          }
                        });
                      },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                // Start/Stop button
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isCapturing ? _stopCapture : _startCapture,
                    icon: Icon(_isCapturing ? Icons.stop : Icons.play_arrow),
                    label: Text(_isCapturing ? 'Stop' : 'Start Capture'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isCapturing
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                      foregroundColor: _isCapturing
                          ? theme.colorScheme.onError
                          : theme.colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Save & Play buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _wavBuffer.isNotEmpty ? _saveWav : null,
                    icon: const Icon(Icons.save),
                    label: Text(
                      'Save WAV (${(_wavBufferBytes / _wavBytesPerSecond).toStringAsFixed(1)}s)',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _savedWavPath != null ? _playWav : null,
                    icon: Icon(_isPlaying ? Icons.stop : Icons.play_circle),
                    label: Text(_isPlaying ? 'Stop' : 'Play Back'),
                    style: _isPlaying
                        ? OutlinedButton.styleFrom(
                            foregroundColor: Colors.orange,
                          )
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Decrypt toggle
            SwitchListTile(
              title: Row(
                children: [
                  Icon(
                    _decryptEnabled ? Icons.lock_open : Icons.lock,
                    color: _decryptEnabled ? Colors.green : Colors.orange,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Text('XOR Decryption'),
                ],
              ),
              subtitle: Text(
                _decryptEnabled
                    ? 'Audio will be decrypted (clean output)'
                    : 'Raw encrypted audio (noise)',
              ),
              value: _decryptEnabled,
              onChanged: (_) => _toggleDecrypt(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWaveform(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.graphic_eq, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Waveform', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              height: 120,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outline.withAlpha(51)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CustomPaint(
                  size: const Size(double.infinity, 120),
                  painter: WaveformPainter(
                    data: _waveformData,
                    color: _decryptEnabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Level meter
            Row(
              children: [
                const Text('RMS: ', style: TextStyle(fontSize: 12)),
                Expanded(
                  child: LinearProgressIndicator(
                    value: _rmsLevel.clamp(0.0, 1.0),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation(
                      _rmsLevel > 0.8
                          ? Colors.red
                          : _rmsLevel > 0.5
                              ? Colors.orange
                              : Colors.green,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 50,
                  child: Text(
                    '${(_rmsLevel * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(fontSize: 12),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStats(ThemeData theme) {
    final durationSec = _totalSamples / 16000.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.analytics, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Statistics', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            _statRow('Status', _isCapturing ? '🟢 Capturing' : '⚪ Idle'),
            _statRow('Decrypt', _decryptEnabled ? '🔓 ON' : '🔒 OFF'),
            _statRow('Seed', '0x${BmcAudioCrypto.defaultSeed.toRadixString(16).toUpperCase()}'),
            _statRow('Sample Rate', '16,000 Hz'),
            _statRow('Format', 'PCM16LE Mono'),
            const Divider(),
            _statRow('Total Samples', _formatNumber(_totalSamples)),
            _statRow('Total Bytes', _formatBytes(_totalBytes)),
            _statRow('Duration', '${durationSec.toStringAsFixed(1)}s'),
            _statRow('Peak Amplitude', '${(_peakAmplitude * 100).toStringAsFixed(1)}%'),
            _statRow('RMS Level', '${(_rmsLevel * 100).toStringAsFixed(1)}%'),
            if (_decoder.crypto != null)
              _statRow('Crypto Sample Index',
                  _formatNumber(_decoder.crypto!.sampleIndex)),
          ],
        ),
      ),
    );
  }

  Widget _buildDebugLog(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bug_report, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Debug Log', style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => setState(() => _debugLog.clear()),
                  tooltip: 'Clear log',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 200,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  _debugLog.isEmpty
                      ? '(no logs yet — tap refresh to scan devices)'
                      : _debugLog.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.greenAccent,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  String _formatNumber(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '${(n / 1000000).toStringAsFixed(2)}M';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

/// Custom painter for audio waveform visualization.
class WaveformPainter extends CustomPainter {
  final List<double> data;
  final Color color;

  WaveformPainter({required this.data, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) {
      // Draw center line when no data
      final paint = Paint()
        ..color = color.withAlpha(51)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      return;
    }

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final centerY = size.height / 2;
    final stepX = size.width / (data.length - 1).clamp(1, double.infinity);

    path.moveTo(0, centerY + data[0] * centerY);
    for (int i = 1; i < data.length; i++) {
      final x = i * stepX;
      final y = centerY + data[i] * centerY;
      path.lineTo(x, y.clamp(0, size.height));
    }

    canvas.drawPath(path, paint);

    // Draw center line
    final centerPaint = Paint()
      ..color = color.withAlpha(26)
      ..strokeWidth = 0.5;
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      centerPaint,
    );
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) =>
      data.length != oldDelegate.data.length ||
      color != oldDelegate.color;
}
