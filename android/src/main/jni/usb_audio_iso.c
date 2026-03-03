/**
 * bmc_usb_audio — Minimal JNI for isochronous USB audio capture on Android.
 *
 * Android's Java USB API doesn't support isochronous transfers.
 * This C code uses USBDEVFS ioctl on the USB file descriptor
 * (from UsbDeviceConnection.getFileDescriptor()) to do isoc reads.
 *
 * Usage from Kotlin:
 *   val fd = connection.fileDescriptor
 *   nativeClaimInterface(fd, interfaceNumber)
 *   nativeSetInterface(fd, interfaceNumber, altSetting)
 *   val data = nativeIsoRead(fd, endpointAddress, maxPacketSize, numPackets)
 *   nativeReleaseInterface(fd, interfaceNumber)
 */

#include <android/log.h>
#include <errno.h>
#include <jni.h>
#include <linux/usbdevice_fs.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>


#define TAG "BmcUsbNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

/* ── Claim/Release Interface ─────────────────────────────────────── */

JNIEXPORT jint JNICALL
Java_com_bmc_audio_bmc_1audio_BmcAudioPlugin_nativeClaimInterface(
    JNIEnv *env, jobject thiz, jint fd, jint interfaceNum) {
  int ret = ioctl(fd, USBDEVFS_CLAIMINTERFACE, &interfaceNum);
  if (ret < 0) {
    LOGE("CLAIMINTERFACE(%d) failed: %s (%d)", interfaceNum, strerror(errno),
         errno);
  } else {
    LOGI("CLAIMINTERFACE(%d): OK", interfaceNum);
  }
  return ret;
}

JNIEXPORT jint JNICALL
Java_com_bmc_audio_bmc_1audio_BmcAudioPlugin_nativeReleaseInterface(
    JNIEnv *env, jobject thiz, jint fd, jint interfaceNum) {
  int ret = ioctl(fd, USBDEVFS_RELEASEINTERFACE, &interfaceNum);
  if (ret < 0) {
    LOGE("RELEASEINTERFACE(%d) failed: %s", interfaceNum, strerror(errno));
  }
  return ret;
}

/* ── Set Alternate Setting ───────────────────────────────────────── */

JNIEXPORT jint JNICALL
Java_com_bmc_audio_bmc_1audio_BmcAudioPlugin_nativeSetInterface(
    JNIEnv *env, jobject thiz, jint fd, jint interfaceNum, jint altSetting) {
  struct usbdevfs_setinterface si;
  si.interface = interfaceNum;
  si.altsetting = altSetting;

  int ret = ioctl(fd, USBDEVFS_SETINTERFACE, &si);
  if (ret < 0) {
    LOGE("SETINTERFACE(intf=%d, alt=%d) failed: %s (%d)", interfaceNum,
         altSetting, strerror(errno), errno);
  } else {
    LOGI("SETINTERFACE(intf=%d, alt=%d): OK", interfaceNum, altSetting);
  }
  return ret;
}

/* ── Isochronous Read ────────────────────────────────────────────── */

/**
 * Submit an isochronous URB and reap it synchronously.
 *
 * @param fd           USB device file descriptor
 * @param endpoint     Endpoint address (e.g. 0x81 for IN endpoint 1)
 * @param maxPacket    Max packet size per frame
 * @param numPackets   Number of isochronous packets per URB (e.g. 8..64)
 * @return byte array of received audio data, or null on error
 */
JNIEXPORT jbyteArray JNICALL
Java_com_bmc_audio_bmc_1audio_BmcAudioPlugin_nativeIsoRead(
    JNIEnv *env, jobject thiz, jint fd, jint endpoint, jint maxPacket,
    jint numPackets) {
  if (numPackets <= 0 || numPackets > 128)
    numPackets = 8;
  if (maxPacket <= 0 || maxPacket > 4096)
    maxPacket = 192;

  int bufferSize = maxPacket * numPackets;

  /* Allocate URB + iso_packet_desc array */
  size_t urbSize = sizeof(struct usbdevfs_urb) +
                   numPackets * sizeof(struct usbdevfs_iso_packet_desc);
  struct usbdevfs_urb *urb = (struct usbdevfs_urb *)calloc(1, urbSize);
  if (!urb) {
    LOGE("Failed to allocate URB");
    return NULL;
  }

  unsigned char *buffer = (unsigned char *)calloc(1, bufferSize);
  if (!buffer) {
    LOGE("Failed to allocate buffer (%d bytes)", bufferSize);
    free(urb);
    return NULL;
  }

  /* Fill URB */
  urb->type = USBDEVFS_URB_TYPE_ISO;
  urb->endpoint = endpoint;
  urb->buffer = buffer;
  urb->buffer_length = bufferSize;
  urb->number_of_packets = numPackets;

  /* Initialize each packet descriptor */
  for (int i = 0; i < numPackets; i++) {
    urb->iso_frame_desc[i].length = maxPacket;
  }

  /* Submit URB */
  int ret = ioctl(fd, USBDEVFS_SUBMITURB, urb);
  if (ret < 0) {
    LOGE("SUBMITURB failed: %s (%d)", strerror(errno), errno);
    free(buffer);
    free(urb);
    return NULL;
  }

  /* Reap URB (blocks until complete) */
  struct usbdevfs_urb *reaped = NULL;
  ret = ioctl(fd, USBDEVFS_REAPURB, &reaped);
  if (ret < 0) {
    LOGE("REAPURB failed: %s (%d)", strerror(errno), errno);
    /* Try to discard */
    ioctl(fd, USBDEVFS_DISCARDURB, urb);
    free(buffer);
    free(urb);
    return NULL;
  }

  /* Collect audio data from completed packets */
  int totalData = 0;
  for (int i = 0; i < numPackets; i++) {
    int actual = urb->iso_frame_desc[i].actual_length;
    int status = urb->iso_frame_desc[i].status;
    if (status == 0 && actual > 0) {
      /* Move data to beginning of collection buffer */
      if (totalData != (int)(maxPacket * i)) {
        memmove(buffer + totalData, buffer + maxPacket * i, actual);
      }
      totalData += actual;
    }
  }

  jbyteArray result = NULL;
  if (totalData > 0) {
    result = (*env)->NewByteArray(env, totalData);
    if (result) {
      (*env)->SetByteArrayRegion(env, result, 0, totalData, (jbyte *)buffer);
    }
  }

  free(buffer);
  free(urb);
  return result;
}
