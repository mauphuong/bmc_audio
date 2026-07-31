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
 *   val h = nativeIsoStart(fd, endpointAddress, maxPacketSize, packetsPerUrb, urbs)
 *   while (capturing) { val n = nativeIsoRead(h, buf, dropped); ... }
 *   nativeIsoStop(h)
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

/* ── Isochronous capture ─────────────────────────────────────────── */

/*
 * A pool of URBs is kept submitted at all times.
 *
 * The previous implementation allocated one URB, submitted it, blocked on
 * REAPURB, copied the data out and freed everything -- then did it all again.
 * Between reaping one URB and submitting the next there was no URB queued for
 * the endpoint, so the host controller stopped issuing IN tokens for it. The
 * device holds its data during such a gap, but its capture ring keeps filling
 * from the microphone at 16 samples/ms while USB drains nothing, and the
 * firmware's rate controller can only claw back one extra sample per packet.
 * A gap over about half a millisecond per 8 ms cycle therefore grows the ring
 * until it overflows, and every overflow is a discontinuity -- the faint
 * crackle heard on Android but not on Linux (which has always kept a queue) or
 * iOS (which does not use isochronous at all).
 *
 * Here numUrbs URBs are submitted up front. Reaping one leaves the rest in
 * flight, so the endpoint stays covered while this thread copies the data out
 * and resubmits.
 */

typedef struct {
  int fd;
  int endpoint;
  int maxPacket;
  int numPackets;
  int numUrbs;
  int urbBytes;                  /* payload bytes per URB */
  struct usbdevfs_urb **urbs;
  unsigned char **buffers;
  int submitted;                 /* URBs currently in flight */
} iso_ctx_t;

static void iso_free(iso_ctx_t *c) {
  if (!c) return;
  if (c->urbs) {
    for (int i = 0; i < c->numUrbs; i++) free(c->urbs[i]);
    free(c->urbs);
  }
  if (c->buffers) {
    for (int i = 0; i < c->numUrbs; i++) free(c->buffers[i]);
    free(c->buffers);
  }
  free(c);
}

static int iso_submit(iso_ctx_t *c, int idx) {
  struct usbdevfs_urb *u = c->urbs[idx];
  memset(u, 0, sizeof(struct usbdevfs_urb) +
                   c->numPackets * sizeof(struct usbdevfs_iso_packet_desc));
  u->type = USBDEVFS_URB_TYPE_ISO;
  u->endpoint = c->endpoint;
  u->buffer = c->buffers[idx];
  u->buffer_length = c->urbBytes;
  u->number_of_packets = c->numPackets;
  u->usercontext = (void *)(intptr_t)idx;
  for (int i = 0; i < c->numPackets; i++) {
    u->iso_frame_desc[i].length = c->maxPacket;
  }
  if (ioctl(c->fd, USBDEVFS_SUBMITURB, u) < 0) {
    return -1;
  }
  c->submitted++;
  return 0;
}

/**
 * Allocate the URB pool and fill the queue.
 *
 * @return opaque handle, or 0 on failure.
 */
JNIEXPORT jlong JNICALL
Java_com_bmc_audio_bmc_1audio_BmcAudioPlugin_nativeIsoStart(
    JNIEnv *env, jobject thiz, jint fd, jint endpoint, jint maxPacket,
    jint numPackets, jint numUrbs) {
  if (numPackets <= 0 || numPackets > 128) numPackets = 8;
  if (maxPacket <= 0 || maxPacket > 4096) maxPacket = 192;
  if (numUrbs <= 1 || numUrbs > 32) numUrbs = 8;

  iso_ctx_t *c = (iso_ctx_t *)calloc(1, sizeof(iso_ctx_t));
  if (!c) return 0;

  c->fd = fd;
  c->endpoint = endpoint;
  c->maxPacket = maxPacket;
  c->numPackets = numPackets;
  c->numUrbs = numUrbs;
  c->urbBytes = maxPacket * numPackets;

  c->urbs = (struct usbdevfs_urb **)calloc(numUrbs, sizeof(void *));
  c->buffers = (unsigned char **)calloc(numUrbs, sizeof(void *));
  if (!c->urbs || !c->buffers) {
    iso_free(c);
    return 0;
  }

  size_t urbSize = sizeof(struct usbdevfs_urb) +
                   numPackets * sizeof(struct usbdevfs_iso_packet_desc);
  for (int i = 0; i < numUrbs; i++) {
    c->urbs[i] = (struct usbdevfs_urb *)calloc(1, urbSize);
    c->buffers[i] = (unsigned char *)calloc(1, c->urbBytes);
    if (!c->urbs[i] || !c->buffers[i]) {
      iso_free(c);
      return 0;
    }
  }

  for (int i = 0; i < numUrbs; i++) {
    if (iso_submit(c, i) < 0) {
      LOGE("SUBMITURB %d failed: %s (%d)", i, strerror(errno), errno);
      if (c->submitted == 0) {
        iso_free(c);
        return 0;
      }
      break; /* partial queue still works, just shallower */
    }
  }

  LOGI("ISO start: ep=0x%02X maxPacket=%d packets/urb=%d urbs=%d (%d ms queued)",
       endpoint, maxPacket, numPackets, c->submitted,
       c->submitted * numPackets);
  return (jlong)(intptr_t)c;
}

/**
 * Reap one completed URB, copy its payload into @p out, then resubmit it.
 *
 * @param out        caller-owned buffer, at least maxPacket*numPackets bytes.
 *                   Reused across calls so the capture loop allocates nothing.
 * @param outDropped int[1] receiving the number of packets in this URB that
 *                   failed. Those carried audio the device already folded into
 *                   its keystream, so Dart re-acquires its position.
 * @return bytes written to @p out, or -1 on error.
 */
JNIEXPORT jint JNICALL
Java_com_bmc_audio_bmc_1audio_BmcAudioPlugin_nativeIsoRead(
    JNIEnv *env, jobject thiz, jlong handle, jbyteArray out,
    jintArray outDropped) {
  iso_ctx_t *c = (iso_ctx_t *)(intptr_t)handle;
  if (!c) return -1;

  struct usbdevfs_urb *reaped = NULL;
  int ret;
  do {
    ret = ioctl(c->fd, USBDEVFS_REAPURB, &reaped);
  } while (ret < 0 && errno == EINTR);

  if (ret < 0) {
    LOGE("REAPURB failed: %s (%d)", strerror(errno), errno);
    return -1;
  }
  c->submitted--;

  int idx = (int)(intptr_t)reaped->usercontext;
  if (idx < 0 || idx >= c->numUrbs) {
    LOGE("REAPURB returned an unknown URB");
    return -1;
  }

  /* Gather the good packets. A packet that completes with zero bytes is not a
   * loss: the endpoint is asynchronous, so the device legitimately returns
   * nothing in a frame it had no data ready for, and its keystream does not
   * advance either. Only a failed packet means bytes went missing.
   */
  unsigned char *buf = c->buffers[idx];
  int total = 0, dropped = 0;
  for (int i = 0; i < c->numPackets; i++) {
    int actual = reaped->iso_frame_desc[i].actual_length;
    int status = reaped->iso_frame_desc[i].status;
    if (status != 0) {
      dropped++;
      continue;
    }
    if (actual > 0) {
      if (total != c->maxPacket * i) {
        memmove(buf + total, buf + c->maxPacket * i, actual);
      }
      total += actual;
    }
  }

  jint cap = (*env)->GetArrayLength(env, out);
  if (total > cap) total = cap;
  if (total > 0) {
    (*env)->SetByteArrayRegion(env, out, 0, total, (jbyte *)buf);
  }

  if (outDropped != NULL && (*env)->GetArrayLength(env, outDropped) > 0) {
    jint d = (jint)dropped;
    (*env)->SetIntArrayRegion(env, outDropped, 0, 1, &d);
  }

  /* Back into the queue. Done after the copy because the controller owns the
   * buffer again the moment this returns.
   */
  if (iso_submit(c, idx) < 0) {
    LOGE("resubmit %d failed: %s (%d)", idx, strerror(errno), errno);
  }

  return total;
}

/**
 * Cancel everything still in flight and release the pool.
 */
JNIEXPORT void JNICALL
Java_com_bmc_audio_bmc_1audio_BmcAudioPlugin_nativeIsoStop(JNIEnv *env,
                                                           jobject thiz,
                                                           jlong handle) {
  iso_ctx_t *c = (iso_ctx_t *)(intptr_t)handle;
  if (!c) return;

  for (int i = 0; i < c->numUrbs; i++) {
    ioctl(c->fd, USBDEVFS_DISCARDURB, c->urbs[i]);
  }
  /* Drain the completion queue so the fd is left clean for the next session. */
  while (c->submitted > 0) {
    struct usbdevfs_urb *r = NULL;
    if (ioctl(c->fd, USBDEVFS_REAPURBNDELAY, &r) < 0) break;
    c->submitted--;
  }

  LOGI("ISO stop");
  iso_free(c);
}
