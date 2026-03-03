import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'bmc_audio_method_channel.dart';

abstract class BmcAudioPlatform extends PlatformInterface {
  /// Constructs a BmcAudioPlatform.
  BmcAudioPlatform() : super(token: _token);

  static final Object _token = Object();

  static BmcAudioPlatform _instance = MethodChannelBmcAudio();

  /// The default instance of [BmcAudioPlatform] to use.
  ///
  /// Defaults to [MethodChannelBmcAudio].
  static BmcAudioPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [BmcAudioPlatform] when
  /// they register themselves.
  static set instance(BmcAudioPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
