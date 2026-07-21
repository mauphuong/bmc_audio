#include "include/bmc_audio/bmc_audio_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>
#include <libusb-1.0/libusb.h>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "bmc_audio_plugin_private.h"

// ─────────────────────────────────────────────────────────────────────────
// BMC Audio — Linux native plugin.
//
// Captures encrypted PCM16LE directly from the BMC S-USB (UAC2.0) device via
// libusb isochronous transfers on the audio-streaming IN endpoint. This is the
// Linux counterpart of the Android JNI (USBDEVFS) path: it bypasses ALSA and
// PulseAudio/PipeWire entirely so the audio bytes are delivered BIT-EXACT,
// which is mandatory for the XOR keystream decryption (done in Dart) to work.
//
// Channels (shared names with Android/iOS):
//   MethodChannel  "bmc_audio"
//   EventChannel   "bmc_audio/audio_stream"  (streams raw encrypted PCM16LE)
// ─────────────────────────────────────────────────────────────────────────

// USB Audio Class constants.
#define USB_CLASS_AUDIO 1
#define USB_SUBCLASS_AUDIOSTREAMING 2

// Isochronous transfer tuning (16 kHz mono 16-bit → 32 bytes / 1 ms packet).
// A single dropped packet permanently desyncs the XOR keystream, and iso data
// is lost whenever the kernel runs out of queued URBs. Under Flutter/GTK CPU
// contention the capture thread can be descheduled for a while, so we keep a
// large in-flight window (16 × 64 ms ≈ 1 s) to ride through scheduling gaps.
#define ISO_NUM_PACKETS 64
#define ISO_NUM_TRANSFERS 16

#define BMC_AUDIO_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), bmc_audio_plugin_get_type(), \
                              BmcAudioPlugin))

struct _BmcAudioPlugin {
  GObject parent_instance;

  FlMethodChannel* method_channel;
  FlEventChannel* event_channel;
  gboolean listening;

  // libusb capture state.
  libusb_context* usb_ctx;
  libusb_device_handle* usb_handle;
  int usb_interface;
  int iso_endpoint;
  int iso_max_packet;
  std::atomic<bool> capturing;
  GThread* capture_thread;
  std::vector<libusb_transfer*>* transfers;
};

G_DEFINE_TYPE(BmcAudioPlugin, bmc_audio_plugin, g_object_get_type())

// ─────────────────────────────────────────────────────────────────────────
// EventChannel plumbing — marshal capture-thread data onto the main thread.
// ─────────────────────────────────────────────────────────────────────────

struct AudioChunk {
  BmcAudioPlugin* self;
  uint8_t* data;
  size_t len;
};

static gboolean send_chunk_idle(gpointer user_data) {
  AudioChunk* chunk = static_cast<AudioChunk*>(user_data);
  BmcAudioPlugin* self = chunk->self;
  if (self->listening && self->event_channel != nullptr) {
    g_autoptr(FlValue) value = fl_value_new_uint8_list(chunk->data, chunk->len);
    fl_event_channel_send(self->event_channel, value, nullptr, nullptr);
  }
  free(chunk->data);
  delete chunk;
  return G_SOURCE_REMOVE;
}

static FlMethodErrorResponse* event_listen_cb(FlEventChannel* channel,
                                              FlValue* args,
                                              gpointer user_data) {
  BmcAudioPlugin* self = BMC_AUDIO_PLUGIN(user_data);
  self->listening = TRUE;
  return nullptr;
}

static FlMethodErrorResponse* event_cancel_cb(FlEventChannel* channel,
                                              FlValue* args,
                                              gpointer user_data) {
  BmcAudioPlugin* self = BMC_AUDIO_PLUGIN(user_data);
  self->listening = FALSE;
  return nullptr;
}

// ─────────────────────────────────────────────────────────────────────────
// libusb helpers
// ─────────────────────────────────────────────────────────────────────────

static gchar* get_usb_string(libusb_device_handle* h, uint8_t idx) {
  if (idx == 0) return g_strdup("");
  unsigned char buf[256];
  int n = libusb_get_string_descriptor_ascii(h, idx, buf, sizeof(buf));
  if (n < 0) return g_strdup("");
  return g_strndup(reinterpret_cast<char*>(buf), n);
}

// Locate the audio-streaming (class=1, subclass=2) isochronous IN endpoint.
// Returns TRUE on success and fills interface/alt/endpoint/max-packet.
static gboolean find_audio_streaming_endpoint(libusb_device* dev,
                                              int* out_intf, int* out_alt,
                                              int* out_ep, int* out_maxpkt) {
  libusb_config_descriptor* cfg = nullptr;
  if (libusb_get_active_config_descriptor(dev, &cfg) != 0) return FALSE;

  gboolean found = FALSE;
  for (int i = 0; i < cfg->bNumInterfaces && !found; i++) {
    const libusb_interface* itf = &cfg->interface[i];
    for (int a = 0; a < itf->num_altsetting && !found; a++) {
      const libusb_interface_descriptor* id = &itf->altsetting[a];
      if (id->bInterfaceClass != USB_CLASS_AUDIO ||
          id->bInterfaceSubClass != USB_SUBCLASS_AUDIOSTREAMING) {
        continue;
      }
      for (int e = 0; e < id->bNumEndpoints; e++) {
        const libusb_endpoint_descriptor* ep = &id->endpoint[e];
        bool is_iso =
            (ep->bmAttributes & 0x03) == LIBUSB_TRANSFER_TYPE_ISOCHRONOUS;
        bool is_in = (ep->bEndpointAddress & LIBUSB_ENDPOINT_IN) != 0;
        if (is_iso && is_in) {
          *out_intf = id->bInterfaceNumber;
          *out_alt = id->bAlternateSetting;
          *out_ep = ep->bEndpointAddress;
          *out_maxpkt = ep->wMaxPacketSize;
          found = TRUE;
          break;
        }
      }
    }
  }
  libusb_free_config_descriptor(cfg);
  return found;
}

// ─────────────────────────────────────────────────────────────────────────
// Device enumeration
// ─────────────────────────────────────────────────────────────────────────

// Returns TRUE if the device exposes a USB Audio Class interface.
static gboolean device_is_audio(libusb_device* dev) {
  libusb_config_descriptor* cfg = nullptr;
  if (libusb_get_active_config_descriptor(dev, &cfg) != 0) return FALSE;
  gboolean audio = FALSE;
  for (int i = 0; i < cfg->bNumInterfaces && !audio; i++) {
    const libusb_interface* itf = &cfg->interface[i];
    for (int a = 0; a < itf->num_altsetting; a++) {
      if (itf->altsetting[a].bInterfaceClass == USB_CLASS_AUDIO) {
        audio = TRUE;
        break;
      }
    }
  }
  libusb_free_config_descriptor(cfg);
  return audio;
}

// Build the list of USB audio devices as FlValue list of maps.
// `full` = include hardware detail fields used by listUsbDevices.
static FlValue* enumerate_devices(BmcAudioPlugin* self, gboolean full) {
  FlValue* list = fl_value_new_list();
  if (self->usb_ctx == nullptr) return list;

  libusb_device** devs = nullptr;
  ssize_t count = libusb_get_device_list(self->usb_ctx, &devs);
  for (ssize_t i = 0; i < count; i++) {
    libusb_device* dev = devs[i];
    libusb_device_descriptor desc;
    if (libusb_get_device_descriptor(dev, &desc) != 0) continue;
    if (!device_is_audio(dev)) continue;

    gchar* product = g_strdup("");
    gchar* manufacturer = g_strdup("");
    libusb_device_handle* h = nullptr;
    if (libusb_open(dev, &h) == 0 && h != nullptr) {
      g_free(product);
      g_free(manufacturer);
      product = get_usb_string(h, desc.iProduct);
      manufacturer = get_usb_string(h, desc.iManufacturer);
      libusb_close(h);
    }
    if (strlen(product) == 0) {
      g_free(product);
      product = g_strdup_printf("USB Audio (VID=0x%04X)", desc.idVendor);
    }

    FlValue* map = fl_value_new_map();
    if (full) {
      fl_value_set_string_take(map, "vendorId", fl_value_new_int(desc.idVendor));
      fl_value_set_string_take(map, "productId",
                               fl_value_new_int(desc.idProduct));
      fl_value_set_string_take(map, "productName", fl_value_new_string(product));
      fl_value_set_string_take(map, "manufacturerName",
                               fl_value_new_string(manufacturer));
      fl_value_set_string_take(map, "isAudioClass", fl_value_new_bool(TRUE));
      fl_value_set_string_take(map, "hasPermission", fl_value_new_bool(TRUE));
      fl_value_set_string_take(map, "interfaceCount", fl_value_new_int(0));
    } else {
      // AudioManager-style entry (matches Dart _listDevicesNative expectations).
      g_autofree gchar* id_str =
          g_strdup_printf("%d", (desc.idVendor << 16) | desc.idProduct);
      fl_value_set_string_take(map, "id", fl_value_new_string(id_str));
      fl_value_set_string_take(map, "name", fl_value_new_string(product));
      fl_value_set_string_take(map, "typeName",
                               fl_value_new_string("USB Audio"));
      fl_value_set_string_take(map, "productName", fl_value_new_string(product));
      fl_value_set_string_take(map, "isUsb", fl_value_new_bool(TRUE));
    }
    fl_value_append_take(list, map);

    g_free(product);
    g_free(manufacturer);
  }
  if (devs != nullptr) libusb_free_device_list(devs, 1);
  return list;
}

// ─────────────────────────────────────────────────────────────────────────
// Isochronous capture
// ─────────────────────────────────────────────────────────────────────────

static void LIBUSB_CALL iso_transfer_cb(libusb_transfer* transfer) {
  BmcAudioPlugin* self = static_cast<BmcAudioPlugin*>(transfer->user_data);
  if (!self->capturing.load()) return;

  // Assemble the completed packets into one contiguous chunk.
  size_t total = 0;
  for (int i = 0; i < transfer->num_iso_packets; i++) {
    libusb_iso_packet_descriptor* d = &transfer->iso_packet_desc[i];
    if (d->status == LIBUSB_TRANSFER_COMPLETED) total += d->actual_length;
  }
  if (total > 0) {
    uint8_t* buf = static_cast<uint8_t*>(malloc(total));
    size_t pos = 0;
    for (int i = 0; i < transfer->num_iso_packets; i++) {
      libusb_iso_packet_descriptor* d = &transfer->iso_packet_desc[i];
      if (d->status == LIBUSB_TRANSFER_COMPLETED && d->actual_length > 0) {
        unsigned char* p = libusb_get_iso_packet_buffer_simple(transfer, i);
        memcpy(buf + pos, p, d->actual_length);
        pos += d->actual_length;
      }
    }
    AudioChunk* chunk = new AudioChunk{self, buf, total};
    g_idle_add(send_chunk_idle, chunk);
  }

  // Resubmit to keep streaming.
  if (self->capturing.load()) {
    libusb_submit_transfer(transfer);
  }
}

static gpointer capture_thread_func(gpointer user_data) {
  BmcAudioPlugin* self = BMC_AUDIO_PLUGIN(user_data);
  while (self->capturing.load()) {
    struct timeval tv = {0, 100000};  // 100 ms
    libusb_handle_events_timeout(self->usb_ctx, &tv);
  }
  return nullptr;
}

// Open the device (by VID/PID, or the first audio-class device if pid<0),
// claim the audio interface and start isochronous streaming.
static FlMethodResponse* start_usb_capture(BmcAudioPlugin* self, int vid,
                                           int pid) {
  if (self->capturing.load()) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "ALREADY_CAPTURING", "USB capture already running", nullptr));
  }
  if (self->usb_ctx == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "NO_USB", "libusb not initialized", nullptr));
  }

  // Find the device.
  libusb_device_handle* h = nullptr;
  if (vid > 0 && pid > 0) {
    h = libusb_open_device_with_vid_pid(self->usb_ctx, vid, pid);
  } else {
    libusb_device** devs = nullptr;
    ssize_t count = libusb_get_device_list(self->usb_ctx, &devs);
    for (ssize_t i = 0; i < count && h == nullptr; i++) {
      if (device_is_audio(devs[i])) libusb_open(devs[i], &h);
    }
    if (devs != nullptr) libusb_free_device_list(devs, 1);
  }
  if (h == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "NOT_FOUND", "USB audio device not found or no permission", nullptr));
  }

  int intf = -1, alt = -1, ep = -1, maxpkt = -1;
  if (!find_audio_streaming_endpoint(libusb_get_device(h), &intf, &alt, &ep,
                                     &maxpkt)) {
    libusb_close(h);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "NO_AUDIO_EP", "No audio streaming isochronous IN endpoint", nullptr));
  }

  libusb_set_auto_detach_kernel_driver(h, 1);
  int r = libusb_claim_interface(h, intf);
  if (r < 0) {
    libusb_close(h);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "CLAIM_FAILED", libusb_strerror(r), nullptr));
  }
  libusb_set_interface_alt_setting(h, intf, alt);

  self->usb_handle = h;
  self->usb_interface = intf;
  self->iso_endpoint = ep;
  self->iso_max_packet = maxpkt;
  self->capturing.store(true);
  self->transfers = new std::vector<libusb_transfer*>();

  // Allocate and submit the isochronous transfer ring.
  for (int i = 0; i < ISO_NUM_TRANSFERS; i++) {
    libusb_transfer* xfer = libusb_alloc_transfer(ISO_NUM_PACKETS);
    uint8_t* buf = static_cast<uint8_t*>(malloc(maxpkt * ISO_NUM_PACKETS));
    libusb_fill_iso_transfer(xfer, h, ep, buf, maxpkt * ISO_NUM_PACKETS,
                             ISO_NUM_PACKETS, iso_transfer_cb, self, 1000);
    libusb_set_iso_packet_lengths(xfer, maxpkt);
    self->transfers->push_back(xfer);
    libusb_submit_transfer(xfer);
  }

  self->capture_thread = g_thread_new("bmc-usb-iso", capture_thread_func, self);

  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(result, "endpoint", fl_value_new_int(ep));
  fl_value_set_string_take(result, "maxPacketSize", fl_value_new_int(maxpkt));
  fl_value_set_string_take(result, "interfaceId", fl_value_new_int(intf));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void stop_usb_capture(BmcAudioPlugin* self) {
  if (!self->capturing.load()) return;
  self->capturing.store(false);

  if (self->capture_thread != nullptr) {
    g_thread_join(self->capture_thread);
    self->capture_thread = nullptr;
  }

  if (self->transfers != nullptr) {
    for (libusb_transfer* xfer : *self->transfers) {
      libusb_cancel_transfer(xfer);
    }
    // Drain any in-flight completions so buffers are safe to free.
    for (int i = 0; i < 10; i++) {
      struct timeval tv = {0, 10000};
      libusb_handle_events_timeout(self->usb_ctx, &tv);
    }
    for (libusb_transfer* xfer : *self->transfers) {
      free(xfer->buffer);
      libusb_free_transfer(xfer);
    }
    delete self->transfers;
    self->transfers = nullptr;
  }

  if (self->usb_handle != nullptr) {
    libusb_set_interface_alt_setting(self->usb_handle, self->usb_interface, 0);
    libusb_release_interface(self->usb_handle, self->usb_interface);
    libusb_close(self->usb_handle);
    self->usb_handle = nullptr;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Method channel dispatch
// ─────────────────────────────────────────────────────────────────────────

static void bmc_audio_plugin_handle_method_call(BmcAudioPlugin* self,
                                                FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "getPlatformVersion") == 0) {
    response = get_platform_version();
  } else if (strcmp(method, "listDevices") == 0) {
    g_autoptr(FlValue) list = enumerate_devices(self, FALSE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(list));
  } else if (strcmp(method, "listUsbDevices") == 0) {
    g_autoptr(FlValue) list = enumerate_devices(self, TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(list));
  } else if (strcmp(method, "requestUsbPermission") == 0) {
    // On Linux, access is governed by udev/plugdev — no runtime prompt.
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "granted", fl_value_new_bool(TRUE));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "startUsbCapture") == 0 ||
             strcmp(method, "startCapture") == 0) {
    int vid = -1, pid = -1;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* v = fl_value_lookup_string(args, "vendorId");
      FlValue* p = fl_value_lookup_string(args, "productId");
      if (v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_INT)
        vid = fl_value_get_int(v);
      if (p != nullptr && fl_value_get_type(p) == FL_VALUE_TYPE_INT)
        pid = fl_value_get_int(p);
    }
    response = start_usb_capture(self, vid, pid);
  } else if (strcmp(method, "stopCapture") == 0) {
    stop_usb_capture(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "isCapturing") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(self->capturing.load());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar* version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void bmc_audio_plugin_dispose(GObject* object) {
  BmcAudioPlugin* self = BMC_AUDIO_PLUGIN(object);
  stop_usb_capture(self);
  if (self->usb_ctx != nullptr) {
    libusb_exit(self->usb_ctx);
    self->usb_ctx = nullptr;
  }
  G_OBJECT_CLASS(bmc_audio_plugin_parent_class)->dispose(object);
}

static void bmc_audio_plugin_class_init(BmcAudioPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = bmc_audio_plugin_dispose;
}

static void bmc_audio_plugin_init(BmcAudioPlugin* self) {
  self->method_channel = nullptr;
  self->event_channel = nullptr;
  self->listening = FALSE;
  self->usb_ctx = nullptr;
  self->usb_handle = nullptr;
  self->usb_interface = -1;
  self->iso_endpoint = -1;
  self->iso_max_packet = 0;
  self->capturing.store(false);
  self->capture_thread = nullptr;
  self->transfers = nullptr;
  if (libusb_init(&self->usb_ctx) != 0) {
    self->usb_ctx = nullptr;
  }
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  BmcAudioPlugin* plugin = BMC_AUDIO_PLUGIN(user_data);
  bmc_audio_plugin_handle_method_call(plugin, method_call);
}

void bmc_audio_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  BmcAudioPlugin* plugin =
      BMC_AUDIO_PLUGIN(g_object_new(bmc_audio_plugin_get_type(), nullptr));

  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  plugin->method_channel =
      fl_method_channel_new(messenger, "bmc_audio", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->method_channel,
                                            method_call_cb,
                                            g_object_ref(plugin), g_object_unref);

  g_autoptr(FlStandardMethodCodec) event_codec = fl_standard_method_codec_new();
  plugin->event_channel = fl_event_channel_new(
      messenger, "bmc_audio/audio_stream", FL_METHOD_CODEC(event_codec));
  fl_event_channel_set_stream_handlers(plugin->event_channel, event_listen_cb,
                                       event_cancel_cb, g_object_ref(plugin),
                                       g_object_unref);

  g_object_unref(plugin);
}
