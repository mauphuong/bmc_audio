#import <Foundation/Foundation.h>

/// Objective-C helper to bridge IOKit USB C API to Swift.
/// IOKit.framework exists on iOS but has no Swift module overlay,
/// so we access it through Objective-C which can import C headers.

NS_ASSUME_NONNULL_BEGIN

@interface BmcUsbHelper : NSObject

/// List connected USB devices, returns array of dictionaries with vendorId, productId, productName.
+ (NSArray<NSDictionary<NSString *, id> *> *)listUsbDevices;

/// Find a USB device by Vendor ID and Product ID.
/// Returns YES if found.
+ (BOOL)findDeviceWithVendorId:(uint16_t)vid productId:(uint16_t)pid;

/// Start USB isochronous capture from the BMC device.
/// Reads raw data from the audio streaming endpoint and delivers via callback.
/// @param vid Vendor ID (e.g., 0x1fc9)
/// @param pid Product ID (e.g., 0x0117)
/// @param interfaceNum USB interface number for audio streaming (e.g., 4)
/// @param altSetting Alternate setting to activate (e.g., 1)
/// @param dataCallback Called on background thread with raw PCM data chunks
/// @param errorCallback Called if capture fails
/// @return Dictionary with endpoint info, or nil on failure
+ (nullable NSDictionary *)startIsocCaptureWithVendorId:(uint16_t)vid
                                              productId:(uint16_t)pid
                                          interfaceNum:(uint8_t)interfaceNum
                                            altSetting:(uint8_t)altSetting
                                          dataCallback:(void (^)(NSData *data))dataCallback
                                         errorCallback:(void (^)(NSString *error))errorCallback;

/// Stop USB isochronous capture.
+ (void)stopIsocCapture;

/// Whether USB capture is currently active.
+ (BOOL)isCapturing;

@end

NS_ASSUME_NONNULL_END
