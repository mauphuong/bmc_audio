// bmc_audio_cli — standalone Linux capture + decrypt tool for the BMC S-USB.
//
// Exercises the exact same pipeline as the Flutter Linux plugin, with no
// Flutter/Dart toolchain required:
//   1. libusb isochronous capture from the audio-streaming IN endpoint
//      (bypasses ALSA/PulseAudio/PipeWire → bit-exact bytes).
//   2. XOR keystream decryption — a faithful C port of lib/src/audio_crypto.dart
//      (mix32 / keystream16), matching firmware source/uac/audio_crypto.c.
//   3. Keystream offset search (port of BmcAudioCrypto.searchOffset).
//   4. Writes <base>_enc.wav (raw encrypted) and <base>_dec.wav (decrypted).
//
// Build:  gcc bmc_audio_cli.c -o bmc_audio_cli $(pkg-config --cflags --libs libusb-1.0) -lm
// Run:    ./bmc_audio_cli [-d seconds] [-o basename] [-s seedHex]
//
// USB access needs no root if the user is in the 'plugdev' group (uaccess ACL).

#include <libusb-1.0/libusb.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define VID 0x1fc9  // NXP / BMC
#define USB_CLASS_AUDIO 1
#define USB_SUBCLASS_AS 2
#define ISO_NPKT 32
#define ISO_NXFER 8

// ── Crypto (port of lib/src/audio_crypto.dart) ───────────────────────────
static uint32_t g_seed = 0xC0FFEE12u;

static uint32_t mix32(uint32_t x) {
  x ^= x >> 16;
  x *= 0x7FEB352Du;
  x ^= x >> 15;
  x *= 0x846CA68Bu;
  x ^= x >> 16;
  return x;
}
static uint16_t keystream16(uint32_t sample_index) {
  return (uint16_t)mix32(g_seed ^ sample_index);
}
// XOR transform in place, starting from keystream index `start`.
static void transform(uint8_t *pcm, size_t nbytes, uint32_t start) {
  size_t samples = nbytes / 2;
  for (size_t i = 0; i < samples; i++) {
    uint16_t k = keystream16(start + (uint32_t)i);
    pcm[i * 2] ^= k & 0xFF;
    pcm[i * 2 + 1] ^= (k >> 8) & 0xFF;
  }
}
// Adjacent-sample correlation (port of scoreAudioLike): 0=noise .. 1=clean.
static double score_audio(const uint8_t *pcm, size_t nbytes) {
  size_t n = nbytes / 2;
  if (n < 64) return 0.0;
  const int16_t *s = (const int16_t *)pcm;
  double mean = 0;
  for (size_t i = 0; i < n; i++) mean += s[i];
  mean /= n;
  double sab = 0, saa = 0, sbb = 0;
  for (size_t i = 0; i + 1 < n; i++) {
    double a = s[i] - mean, b = s[i + 1] - mean;
    sab += a * b; saa += a * a; sbb += b * b;
  }
  double d = saa * sbb;
  return d < 1e-12 ? 0.0 : fabs(sab / sqrt(d));
}
// Mean absolute difference between adjacent samples (port of
// meanAdjacentDiff). Unlike score_audio this also works during silence:
// correctly-decrypted silence is all zeros, while a wrong keystream offset
// produces pseudo-random noise averaging about 21800.
static double mean_adjacent_diff(const uint8_t *pcm, size_t nbytes) {
  size_t n = nbytes / 2;
  if (n < 2) return 0.0;
  const int16_t *s = (const int16_t *)pcm;
  double sum = 0;
  for (size_t i = 1; i < n; i++) {
    int d = (int)s[i] - (int)s[i - 1];
    sum += d < 0 ? -d : d;
  }
  return sum / (double)(n - 1);
}

// Search for the best keystream offset (port of searchOffset).
//
// This used to step 16 samples at a time on the assumption that every USB
// packet carries exactly 16 samples, so the offset had to be a multiple of 16.
// The firmware's audio endpoint is now asynchronous and varies the payload
// between 15 and 17 samples to track the host clock, so the offset can be any
// integer. Scoring gives no gradient to follow -- only the exact offset scores
// well -- so a grid that steps over the true value finds nothing at all.
//
// Instead every offset is probed with a short window (cheap, and just as
// decisive because a wrong offset is indistinguishable from noise), then the
// best few candidates are confirmed against a long window.
#define PROBE_SAMPLES 96
#define VERIFY_SAMPLES 2048
#define PROBE_CANDIDATES 8

static uint32_t search_offset(const uint8_t *pcm, size_t nbytes,
                              uint32_t max_off, double *best_score) {
  size_t avail = nbytes / 2;
  size_t probe_n = avail < PROBE_SAMPLES ? avail : PROBE_SAMPLES;
  size_t verify_n = avail < VERIFY_SAMPLES ? avail : VERIFY_SAMPLES;
  size_t probe_bytes = probe_n * 2, verify_bytes = verify_n * 2;

  uint8_t *tmp = malloc(verify_bytes > probe_bytes ? verify_bytes : probe_bytes);
  if (!tmp) { *best_score = 0; return 0; }

  // Probe pass: keep the best PROBE_CANDIDATES offsets by adjacent difference.
  uint32_t cand[PROBE_CANDIDATES];
  double cand_diff[PROBE_CANDIDATES];
  int ncand = 0;

  for (uint32_t off = 0; off <= max_off; off++) {
    memcpy(tmp, pcm, probe_bytes); transform(tmp, probe_bytes, off);
    double d = mean_adjacent_diff(tmp, probe_bytes);

    if (ncand < PROBE_CANDIDATES) {
      cand[ncand] = off; cand_diff[ncand] = d; ncand++;
    } else {
      int worst = 0;
      for (int i = 1; i < ncand; i++)
        if (cand_diff[i] > cand_diff[worst]) worst = i;
      if (d < cand_diff[worst]) { cand[worst] = off; cand_diff[worst] = d; }
    }
  }

  // Verify pass: re-score the survivors over a much longer window.
  uint32_t best = ncand > 0 ? cand[0] : 0;
  double best_diff = 1e30;
  for (int i = 0; i < ncand; i++) {
    memcpy(tmp, pcm, verify_bytes); transform(tmp, verify_bytes, cand[i]);
    double d = mean_adjacent_diff(tmp, verify_bytes);
    if (d < best_diff) { best_diff = d; best = cand[i]; }
  }

  // Report correlation at the chosen offset (informational only: high for
  // speech, near zero for silence, both of which are valid locks).
  memcpy(tmp, pcm, verify_bytes); transform(tmp, verify_bytes, best);
  *best_score = score_audio(tmp, verify_bytes);

  free(tmp);
  return best;
}

// ── WAV writer (PCM16LE mono 16 kHz) ─────────────────────────────────────
static void write_wav(const char *path, const uint8_t *pcm, size_t n) {
  FILE *f = fopen(path, "wb");
  if (!f) { perror("fopen"); return; }
  uint32_t rate = 16000, byte_rate = 16000 * 2, ds = (uint32_t)n, sz = 16;
  uint16_t ch = 1, ba = 2, bits = 16, fmt = 1;
  fwrite("RIFF", 1, 4, f); uint32_t r = 36 + ds; fwrite(&r, 4, 1, f);
  fwrite("WAVEfmt ", 1, 8, f); fwrite(&sz, 4, 1, f);
  fwrite(&fmt, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f);
  fwrite(&byte_rate, 4, 1, f); fwrite(&ba, 2, 1, f); fwrite(&bits, 2, 1, f);
  fwrite("data", 1, 4, f); fwrite(&ds, 4, 1, f);
  fwrite(pcm, 1, n, f);
  fclose(f);
}

// ── Capture state ────────────────────────────────────────────────────────
static uint8_t *g_buf; static size_t g_cap, g_len; static volatile int g_run = 1;

// Transport health. The payload size histogram is the direct read-out of the
// firmware's asynchronous rate controller: it steers the capture ring towards
// a target fill level by sending one sample more or less than nominal, so a
// healthy stream shows mostly 32-byte packets with a sprinkling of 30 and 34.
// All-32 means the controller never engages; a lopsided split means the device
// and host clocks are further apart than one sample per frame can correct.
#define PKT_HIST_MAX 40
static unsigned long g_pkt_hist[PKT_HIST_MAX + 1];
static unsigned long g_pkt_oversize, g_pkt_zero, g_pkt_err, g_pkt_ok;

static void LIBUSB_CALL cb(struct libusb_transfer *x) {
  if (!g_run) return;
  for (int i = 0; i < x->num_iso_packets; i++) {
    struct libusb_iso_packet_descriptor *d = &x->iso_packet_desc[i];
    if (d->status != LIBUSB_TRANSFER_COMPLETED) { g_pkt_err++; continue; }

    if (d->actual_length == 0) {
      // Legitimate on an asynchronous endpoint: the device had nothing ready
      // for that frame and its keystream did not advance either.
      g_pkt_zero++;
      continue;
    }

    g_pkt_ok++;
    if (d->actual_length <= PKT_HIST_MAX) g_pkt_hist[d->actual_length]++;
    else g_pkt_oversize++;

    unsigned char *p = libusb_get_iso_packet_buffer_simple(x, i);
    if (g_len + d->actual_length <= g_cap) {
      memcpy(g_buf + g_len, p, d->actual_length);
      g_len += d->actual_length;
    }
  }
  if (g_run) libusb_submit_transfer(x);
}

static void print_transport_stats(void) {
  printf("\n── Transport ──────────────────────────────────────────\n");
  printf("packets: %lu ok, %lu zero-length, %lu failed\n",
         g_pkt_ok, g_pkt_zero, g_pkt_err);
  if (g_pkt_err)
    printf("  WARNING: %lu failed packet(s) — each one desynchronises the "
           "keystream\n", g_pkt_err);

  printf("payload size histogram (bytes -> packets):\n");
  for (int i = 0; i <= PKT_HIST_MAX; i++)
    if (g_pkt_hist[i])
      printf("  %2d bytes (%2d samples): %8lu  %5.1f%%\n", i, i / 2,
             g_pkt_hist[i], 100.0 * g_pkt_hist[i] / (double)(g_pkt_ok ? g_pkt_ok : 1));
  if (g_pkt_oversize) printf("  >%d bytes: %lu\n", PKT_HIST_MAX, g_pkt_oversize);
}

// Scan for the audio-streaming (class=1/subclass=2) iso IN endpoint.
static int find_ep(libusb_device *dev, int *intf, int *alt, int *ep, int *mpk) {
  struct libusb_config_descriptor *cfg;
  if (libusb_get_active_config_descriptor(dev, &cfg)) return 0;
  int ok = 0;
  for (int i = 0; i < cfg->bNumInterfaces && !ok; i++)
    for (int a = 0; a < cfg->interface[i].num_altsetting && !ok; a++) {
      const struct libusb_interface_descriptor *id =
          &cfg->interface[i].altsetting[a];
      if (id->bInterfaceClass != USB_CLASS_AUDIO ||
          id->bInterfaceSubClass != USB_SUBCLASS_AS) continue;
      for (int e = 0; e < id->bNumEndpoints; e++) {
        const struct libusb_endpoint_descriptor *epd = &id->endpoint[e];
        if ((epd->bmAttributes & 3) == LIBUSB_TRANSFER_TYPE_ISOCHRONOUS &&
            (epd->bEndpointAddress & LIBUSB_ENDPOINT_IN)) {
          *intf = id->bInterfaceNumber; *alt = id->bAlternateSetting;
          *ep = epd->bEndpointAddress; *mpk = epd->wMaxPacketSize; ok = 1; break;
        }
      }
    }
  libusb_free_config_descriptor(cfg);
  return ok;
}

int main(int argc, char **argv) {
  double secs = 5.0; const char *base = "bmc_capture";
  for (int i = 1; i < argc - 1; i++) {
    if (!strcmp(argv[i], "-d")) secs = atof(argv[++i]);
    else if (!strcmp(argv[i], "-o")) base = argv[++i];
    else if (!strcmp(argv[i], "-s")) g_seed = (uint32_t)strtoul(argv[++i], 0, 16);
  }
  printf("BMC S-USB capture: %.1fs, seed=0x%08X\n", secs, g_seed);

  libusb_context *ctx; libusb_init(&ctx);
  libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, VID, 0x0117);
  if (!h) {  // fall back to first audio-class 1fc9 device
    libusb_device **devs; ssize_t n = libusb_get_device_list(ctx, &devs);
    for (ssize_t i = 0; i < n && !h; i++) {
      struct libusb_device_descriptor dd;
      if (!libusb_get_device_descriptor(devs[i], &dd) && dd.idVendor == VID) {
        int a, b, c, d2; if (find_ep(devs[i], &a, &b, &c, &d2)) libusb_open(devs[i], &h);
      }
    }
    libusb_free_device_list(devs, 1);
  }
  if (!h) { fprintf(stderr, "Device not found (or no permission)\n"); return 1; }

  int intf, alt, ep, mpk;
  if (!find_ep(libusb_get_device(h), &intf, &alt, &ep, &mpk)) {
    fprintf(stderr, "No audio-streaming iso IN endpoint\n"); return 2;
  }
  printf("Endpoint: intf=%d alt=%d EP=0x%02X maxpkt=%d\n", intf, alt, ep, mpk);

  libusb_set_auto_detach_kernel_driver(h, 1);
  int r = libusb_claim_interface(h, intf);
  if (r < 0) { fprintf(stderr, "claim: %s\n", libusb_strerror(r)); return 3; }
  libusb_set_interface_alt_setting(h, intf, alt);

  g_cap = (size_t)(secs * 32000) + 65536; g_buf = malloc(g_cap); g_len = 0;
  struct libusb_transfer *xf[ISO_NXFER];
  for (int i = 0; i < ISO_NXFER; i++) {
    xf[i] = libusb_alloc_transfer(ISO_NPKT);
    uint8_t *b = malloc(mpk * ISO_NPKT);
    libusb_fill_iso_transfer(xf[i], h, ep, b, mpk * ISO_NPKT, ISO_NPKT, cb, 0, 1000);
    libusb_set_iso_packet_lengths(xf[i], mpk);
    libusb_submit_transfer(xf[i]);
  }
  struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
  printf("Capturing...\n");
  while (g_run) {
    struct timeval tv = {0, 100000}; libusb_handle_events_timeout(ctx, &tv);
    struct timespec t1; clock_gettime(CLOCK_MONOTONIC, &t1);
    if ((t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9 >= secs) g_run = 0;
  }
  libusb_set_interface_alt_setting(h, intf, 0);
  libusb_release_interface(h, intf);
  libusb_close(h); libusb_exit(ctx);

  printf("Captured %zu bytes (~%.2fs)\n", g_len, g_len / 32000.0);
  print_transport_stats();
  printf("\n── Decrypt ────────────────────────────────────────────\n");
  double raw = score_audio(g_buf, g_len);
  double best; uint32_t off = search_offset(g_buf, g_len, 16000, &best);
  uint8_t *dec = malloc(g_len); memcpy(dec, g_buf, g_len);
  transform(dec, g_len, off);
  double decs = score_audio(dec, g_len);
  printf("Score RAW (encrypted): %.4f\n", raw);
  printf("Offset found: %u  (search score %.4f)\n", off, best);
  printf("Score DECRYPTED:       %.4f  %s\n", decs,
         decs > 0.3 ? "-> clean audio :)" : "-> check seed/device");

  char p[512];
  snprintf(p, sizeof p, "%s_enc.wav", base); write_wav(p, g_buf, g_len);
  printf("Wrote %s\n", p);
  snprintf(p, sizeof p, "%s_dec.wav", base); write_wav(p, dec, g_len);
  printf("Wrote %s\n", p);
  return 0;
}
