#import "BmcUsbHelper.h"
#import <IOKit/IOKitLib.h>

@implementation BmcUsbHelper

+ (NSArray<NSDictionary<NSString *, id> *> *)listUsbDevices {
    NSMutableArray *devices = [NSMutableArray array];

    // Use IOKit registry to find USB devices (registry access IS available on iOS)
    CFMutableDictionaryRef matchingDict = IOServiceMatching("IOUSBHostDevice");
    if (!matchingDict) {
        NSLog(@"BmcUsbHelper: Failed to create matching dictionary, trying IOUSBDevice");
        matchingDict = IOServiceMatching("IOUSBDevice");
        if (!matchingDict) return devices;
    }

    io_iterator_t iterator = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator);
    if (kr != KERN_SUCCESS) {
        NSLog(@"BmcUsbHelper: IOServiceGetMatchingServices failed: 0x%X", kr);
        return devices;
    }

    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != 0) {
        uint16_t vid = 0, pid = 0;
        NSString *productName = @"";

        // Get VID
        CFTypeRef vidRef = IORegistryEntryCreateCFProperty(service, CFSTR("idVendor"), kCFAllocatorDefault, 0);
        if (vidRef) {
            CFNumberGetValue(vidRef, kCFNumberSInt16Type, &vid);
            CFRelease(vidRef);
        }

        // Get PID
        CFTypeRef pidRef = IORegistryEntryCreateCFProperty(service, CFSTR("idProduct"), kCFAllocatorDefault, 0);
        if (pidRef) {
            CFNumberGetValue(pidRef, kCFNumberSInt16Type, &pid);
            CFRelease(pidRef);
        }

        // Get product name
        CFTypeRef nameRef = IORegistryEntryCreateCFProperty(service, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
        if (nameRef) {
            productName = (__bridge_transfer NSString *)nameRef;
        }

        if (vid > 0) {
            NSDictionary *info = @{
                @"vendorId": @(vid),
                @"productId": @(pid),
                @"productName": productName ?: @"",
                @"name": productName.length > 0 ? productName :
                    [NSString stringWithFormat:@"USB (VID=0x%04X)", vid],
                @"isAudioClass": @(vid == 0x1fc9),
                @"hasPermission": @YES,
            };
            [devices addObject:info];
            NSLog(@"BmcUsbHelper: USB VID=0x%04X PID=0x%04X \"%@\"", vid, pid, productName);
        }

        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);

    return devices;
}

+ (BOOL)findDeviceWithVendorId:(uint16_t)vid productId:(uint16_t)pid {
    CFMutableDictionaryRef matchingDict = IOServiceMatching("IOUSBHostDevice");
    if (!matchingDict) matchingDict = IOServiceMatching("IOUSBDevice");
    if (!matchingDict) return NO;

    CFDictionarySetValue(matchingDict, CFSTR("idVendor"),
                         (__bridge CFNumberRef)@(vid));
    CFDictionarySetValue(matchingDict, CFSTR("idProduct"),
                         (__bridge CFNumberRef)@(pid));

    io_iterator_t iterator = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator);
    if (kr != KERN_SUCCESS) return NO;

    io_service_t service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);

    if (service != 0) {
        IOObjectRelease(service);
        return YES;
    }
    return NO;
}

+ (nullable NSDictionary *)startIsocCaptureWithVendorId:(uint16_t)vid
                                              productId:(uint16_t)pid
                                          interfaceNum:(uint8_t)interfaceNum
                                            altSetting:(uint8_t)altSetting
                                          dataCallback:(void (^)(NSData *data))dataCallback
                                         errorCallback:(void (^)(NSString *error))errorCallback {
    // IOKit USB device interface APIs (IOUSBDeviceInterface, IOUSBInterfaceInterface,
    // ReadIsochPipe) are NOT available on iOS. The USB-specific IOKit headers
    // (IOKit/usb/IOUSBLib.h) only exist in the macOS SDK.
    //
    // On iOS, only IOKitLib.h is available for IORegistry access.
    // Raw USB isochronous transfer requires either:
    // 1. DriverKit (iPadOS 16+ with M-series chip)
    // 2. Or a firmware-side solution
    NSLog(@"BmcUsbHelper: IOKit USB direct access (IOUSBLib) is NOT available on iOS.");
    NSLog(@"BmcUsbHelper: iOS only provides IOKit registry access (IOKitLib), not USB transfer APIs.");
    NSLog(@"BmcUsbHelper: Raw USB isochronous transfer requires DriverKit (iPadOS M-series).");

    errorCallback(@"Raw USB access not available on iOS. "
                  "IOKit USB transfer APIs (IOUSBDeviceInterface) are macOS-only. "
                  "DriverKit on iPadOS with M-series chip is required for raw USB isochronous transfer.");
    return nil;
}

+ (void)stopIsocCapture {
    NSLog(@"BmcUsbHelper: No active capture to stop");
}

+ (BOOL)isCapturing {
    return NO;
}

@end
