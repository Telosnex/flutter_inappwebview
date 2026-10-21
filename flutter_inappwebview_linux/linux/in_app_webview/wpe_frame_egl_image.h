#ifndef FLUTTER_INAPPWEBVIEW_LINUX_WPE_FRAME_EGL_IMAGE_H_
#define FLUTTER_INAPPWEBVIEW_LINUX_WPE_FRAME_EGL_IMAGE_H_

#include <memory>

// A zero-copy frame from InAppWebView::GetCurrentFrame, as an EGL image on
// the EGL display of the GL context current on the calling thread.
//
// WPEPlatform: the frame holds a DMA-BUF WPEBuffer. An EGL image only works
// on the display that created it, and WPE's offscreen display is not the one
// Flutter's GTK context uses; binding an image from it fails with
// GL_INVALID_VALUE and the view stays black (2026-10-21, Raspberry Pi CM5,
// V3D). So the image is made here from the buffer's DMA-BUF planes, once per
// buffer and display (WebKit rotates through about ten buffers), and destroyed
// when WebKit frees the buffer. The frame keeps the buffer alive while the
// image is bound.
//
// Legacy WPEBackend-FDO: the frame already is an EGL image; returned as is.
//
// Returns null if there is no current EGL display or the import fails; then
// wpe_frame_egl_image_failed() is true and the caller should use pixels.
void* wpe_frame_egl_image_for_current_context(const std::shared_ptr<void>& frame);

// True after an import failed. Zero-copy is then off for the process (the
// cause, a GLX context or an unsupported format or modifier, does not go
// away), and InAppWebView imports DMA-BUF frames to pixels instead.
bool wpe_frame_egl_image_failed();

#endif  // FLUTTER_INAPPWEBVIEW_LINUX_WPE_FRAME_EGL_IMAGE_H_
