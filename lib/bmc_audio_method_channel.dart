import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bmc_audio_platform_interface.dart';

/// An implementation of [BmcAudioPlatform] that uses method channels.
class MethodChannelBmcAudio extends BmcAudioPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('bmc_audio');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
