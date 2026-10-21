#include "wpe_frame_egl_image.h"

#include <atomic>
#include <cstdint>
#include <mutex>
#include <vector>

#include <epoxy/egl.h>

#ifdef HAVE_WPE_PLATFORM
#include <wpe/wpe-platform.h>
#endif

#include "../utils/log.h"

using flutter_inappwebview_plugin::errorLog;

namespace {

std::atomic<bool> g_import_failed{false};

#ifdef HAVE_WPE_PLATFORM

// DRM_FORMAT_MOD_INVALID, without needing drm_fourcc.h.
constexpr uint64_t kModInvalid = 0x00ffffffffffffffULL;

struct CachedImage {
  EGLDisplay display;
  EGLImageKHR image;
};

// Images per buffer, one per EGL display that imported it. Guarded by
// g_cache_mutex: the texture imports on Flutter's raster thread, the in-app
// browser on the main thread, and WebKit frees buffers on the main thread.
struct CachedImages {
  std::vector<CachedImage> images;
};

std::mutex g_cache_mutex;

GQuark CacheQuark() {
  static GQuark quark =
      g_quark_from_static_string("flutter-inappwebview-egl-images");
  return quark;
}

void DestroyCachedImages(gpointer data) {
  auto* cached = static_cast<CachedImages*>(data);
  // eglDestroyImageKHR needs the display, not a current context. The buffer
  // is only freed once no frame holds it, so no texture still binds these.
  for (const auto& entry : cached->images) {
    eglDestroyImageKHR(entry.display, entry.image);
  }
  delete cached;
}

bool HasExtension(EGLDisplay display, const char* name) {
  return epoxy_has_egl_extension(display, name);
}

EGLImageKHR CreateImage(EGLDisplay display, WPEBufferDMABuf* dmabuf,
                        int width, int height) {
  static const EGLint kFd[] = {EGL_DMA_BUF_PLANE0_FD_EXT, EGL_DMA_BUF_PLANE1_FD_EXT,
                               EGL_DMA_BUF_PLANE2_FD_EXT, EGL_DMA_BUF_PLANE3_FD_EXT};
  static const EGLint kOffset[] = {
      EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGL_DMA_BUF_PLANE1_OFFSET_EXT,
      EGL_DMA_BUF_PLANE2_OFFSET_EXT, EGL_DMA_BUF_PLANE3_OFFSET_EXT};
  static const EGLint kPitch[] = {
      EGL_DMA_BUF_PLANE0_PITCH_EXT, EGL_DMA_BUF_PLANE1_PITCH_EXT,
      EGL_DMA_BUF_PLANE2_PITCH_EXT, EGL_DMA_BUF_PLANE3_PITCH_EXT};
  static const EGLint kModLo[] = {
      EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
      EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT};
  static const EGLint kModHi[] = {
      EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
      EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT};

  const guint32 planes = wpe_buffer_dma_buf_get_n_planes(dmabuf);
  if (planes == 0 || planes > 4) {
    return EGL_NO_IMAGE_KHR;
  }
  const uint64_t modifier = wpe_buffer_dma_buf_get_modifier(dmabuf);
  const bool use_modifier =
      modifier != kModInvalid &&
      HasExtension(display, "EGL_EXT_image_dma_buf_import_modifiers");

  std::vector<EGLint> attribs = {
      EGL_WIDTH, width,
      EGL_HEIGHT, height,
      EGL_LINUX_DRM_FOURCC_EXT,
      static_cast<EGLint>(wpe_buffer_dma_buf_get_format(dmabuf)),
  };
  for (guint32 i = 0; i < planes; i++) {
    attribs.insert(attribs.end(),
                   {kFd[i], wpe_buffer_dma_buf_get_fd(dmabuf, i),
                    kOffset[i],
                    static_cast<EGLint>(wpe_buffer_dma_buf_get_offset(dmabuf, i)),
                    kPitch[i],
                    static_cast<EGLint>(wpe_buffer_dma_buf_get_stride(dmabuf, i))});
    if (use_modifier) {
      attribs.insert(attribs.end(),
                     {kModLo[i], static_cast<EGLint>(modifier & 0xffffffff),
                      kModHi[i], static_cast<EGLint>(modifier >> 32)});
    }
  }
  attribs.push_back(EGL_NONE);

  return eglCreateImageKHR(display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT,
                           nullptr, attribs.data());
}

void Fail(const char* why) {
  if (!g_import_failed.exchange(true)) {
    errorLog(std::string("Zero-copy WebView frames are off, using pixels: ") +
             why);
  }
}

#endif  // HAVE_WPE_PLATFORM

}  // namespace

void* wpe_frame_egl_image_for_current_context(const std::shared_ptr<void>& frame) {
  if (frame == nullptr || g_import_failed.load()) {
    return nullptr;
  }
#ifdef HAVE_WPE_PLATFORM
  auto* buffer = static_cast<WPEBuffer*>(frame.get());
  if (!WPE_IS_BUFFER_DMA_BUF(buffer)) {
    return nullptr;
  }
  EGLDisplay display = eglGetCurrentDisplay();
  if (display == EGL_NO_DISPLAY) {
    // GDK on X11 uses GLX, which cannot import DMA-BUFs through EGL.
    Fail("no current EGL display (GLX?)");
    return nullptr;
  }

  std::lock_guard<std::mutex> lock(g_cache_mutex);
  auto* cached = static_cast<CachedImages*>(
      g_object_get_qdata(G_OBJECT(buffer), CacheQuark()));
  if (cached != nullptr) {
    for (const auto& entry : cached->images) {
      if (entry.display == display) {
        return entry.image;
      }
    }
  }

  if (!HasExtension(display, "EGL_EXT_image_dma_buf_import")) {
    Fail("EGL_EXT_image_dma_buf_import is missing");
    return nullptr;
  }
  EGLImageKHR image =
      CreateImage(display, WPE_BUFFER_DMA_BUF(buffer), wpe_buffer_get_width(buffer),
                  wpe_buffer_get_height(buffer));
  if (image == EGL_NO_IMAGE_KHR) {
    Fail("eglCreateImageKHR failed for the frame's DMA-BUF");
    return nullptr;
  }
  if (cached == nullptr) {
    cached = new CachedImages();
    g_object_set_qdata_full(G_OBJECT(buffer), CacheQuark(), cached,
                            DestroyCachedImages);
  }
  cached->images.push_back({display, image});
  return image;
#else
  return frame.get();
#endif
}

bool wpe_frame_egl_image_failed() {
  return g_import_failed.load();
}
