/// BMC Audio Device — Wrapper around audio capture device information.
///
/// Provides device enumeration and BMC USB device auto-detection.
class BmcAudioDevice {
  /// Platform-specific device identifier.
  final String id;

  /// Human-readable device name.
  final String name;

  /// Whether this device appears to be a USB audio device.
  final bool isUsb;

  /// Whether this device appears to be a BMC device (by name heuristic).
  final bool isBmc;

  /// USB Vendor ID (Android only, for direct USB capture).
  final int? vendorId;

  /// USB Product ID (Android only, for direct USB capture).
  final int? productId;

  const BmcAudioDevice({
    required this.id,
    required this.name,
    this.isUsb = false,
    this.isBmc = false,
    this.vendorId,
    this.productId,
  });

  @override
  String toString() =>
      'BmcAudioDevice(id: $id, name: "$name", isUsb: $isUsb, isBmc: $isBmc'
      '${vendorId != null ? ", vid=0x${vendorId!.toRadixString(16)}" : ""}'
      '${productId != null ? ", pid=0x${productId!.toRadixString(16)}" : ""}'
      ')';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BmcAudioDevice &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  /// Heuristic to determine if a device name looks like a USB audio device.
  static bool looksLikeUsb(String name) {
    final lower = name.toLowerCase();
    return lower.contains('usb') ||
        lower.contains('external') ||
        lower.contains('uac');
  }

  /// Heuristic to determine if a device name looks like a BMC device.
  static bool looksLikeBmc(String name) {
    final lower = name.toLowerCase();
    return lower.contains('s-usb') ||
        lower.contains('bmc audio') ||
        lower.contains('aio') ||
        lower.contains('bmc mic');
  }

  /// Create a [BmcAudioDevice] from a raw device map (e.g. from flutter_recorder).
  factory BmcAudioDevice.fromRecorderDevice({
    required String id,
    required String name,
  }) {
    return BmcAudioDevice(
      id: id,
      name: name,
      isUsb: looksLikeUsb(name),
      isBmc: looksLikeBmc(name),
    );
  }
}
