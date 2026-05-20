#include "headless_in_app_webview.h"

#include <cstring>
#include <cstdio>

#include "../utils/flutter.h"
#include "../utils/log.h"
#include "headless_in_app_webview_manager.h"
#include "headless_webview_channel_delegate.h"

namespace flutter_inappwebview_plugin {

HeadlessInAppWebView::HeadlessInAppWebView(HeadlessInAppWebViewManager* manager,
                                           const HeadlessInAppWebViewCreationParams& params,
                                           const InAppWebViewCreationParams& webviewParams)
    : manager_(manager), id_(params.id), width_(params.initialWidth), height_(params.initialHeight) {
  debugLog("HeadlessInAppWebView::HeadlessInAppWebView id=" + id_);
  std::fprintf(stderr, "[flutter_inappwebview_linux] HeadlessInAppWebView ctor start id=%s\n", id_.c_str());

  // Create the underlying InAppWebView without initial content. The regular
  // InAppWebView constructor loads initialUrlRequest/initialData immediately,
  // but headless still needs to attach its method channels and notify Dart's
  // onWebViewCreated first. Otherwise onLoadStop can fire before Dart registers
  // JavaScript handlers, or before Dart can observe lifecycle callbacks.
  InAppWebViewCreationParams deferredLoadParams = webviewParams;
  deferredLoadParams.initialUrlRequest.reset();
  deferredLoadParams.initialFile.reset();
  deferredLoadParams.initialData.reset();
  deferredLoadParams.initialDataBaseUrl.reset();
  deferredLoadParams.initialDataMimeType.reset();
  deferredLoadParams.initialDataEncoding.reset();

  // Create the underlying InAppWebView.
  // Use 0 as the numeric ID since we use string ID for headless webviews.
  webview_ = std::make_shared<InAppWebView>(manager_->registrar(), manager_->messenger(), 0,
                                            deferredLoadParams);
  std::fprintf(stderr, "[flutter_inappwebview_linux] HeadlessInAppWebView underlying InAppWebView created id=%s\n", id_.c_str());

  // CRITICAL: Attach the method channel to the InAppWebView using the string ID.
  // This creates the channel at "com.pichillilorenzo/flutter_inappwebview_<id>"
  // which the Dart LinuxInAppWebViewController expects.
  webview_->AttachChannel(manager_->messenger(), id_, false);
  std::fprintf(stderr, "[flutter_inappwebview_linux] HeadlessInAppWebView webview channel attached id=%s\n", id_.c_str());

  // Set the initial size
  webview_->setSize(static_cast<int>(width_), static_cast<int>(height_));

  // Create the channel delegate for this headless webview
  // This handles headless-specific methods like setSize, getSize, dispose
  channelDelegate_ = std::make_unique<HeadlessWebViewChannelDelegate>(
      this, manager_->messenger(), id_);
  std::fprintf(stderr, "[flutter_inappwebview_linux] HeadlessInAppWebView ctor done id=%s\n", id_.c_str());
}

HeadlessInAppWebView::~HeadlessInAppWebView() {
  debugLog("HeadlessInAppWebView::~HeadlessInAppWebView id=" + id_);

  channelDelegate_.reset();
  webview_.reset();
}

void HeadlessInAppWebView::setSize(double width, double height) {
  width_ = width;
  height_ = height;
  if (webview_) {
    webview_->setSize(static_cast<int>(width_), static_cast<int>(height_));
  }
}

void HeadlessInAppWebView::getSize(double* width, double* height) const {
  if (width) *width = width_;
  if (height) *height = height_;
}

void HeadlessInAppWebView::loadInitialContent(const InAppWebViewCreationParams& webviewParams) {
  if (!webview_) {
    std::fprintf(stderr, "[flutter_inappwebview_linux] HeadlessInAppWebView loadInitialContent skipped: no webview id=%s\n", id_.c_str());
    return;
  }

  std::fprintf(stderr, "[flutter_inappwebview_linux] HeadlessInAppWebView loadInitialContent start id=%s\n", id_.c_str());
  if (webviewParams.initialUrlRequest.has_value()) {
    webview_->loadUrl(webviewParams.initialUrlRequest.value());
  } else if (webviewParams.initialData.has_value()) {
    std::string mimeType = webviewParams.initialDataMimeType.value_or("text/html");
    std::string encoding = webviewParams.initialDataEncoding.value_or("UTF-8");
    std::string baseUrl = webviewParams.initialDataBaseUrl.value_or("about:blank");
    webview_->loadData(webviewParams.initialData.value(), mimeType, encoding, baseUrl);
  } else if (webviewParams.initialFile.has_value()) {
    webview_->loadFile(webviewParams.initialFile.value());
  } else {
    std::fprintf(stderr, "[flutter_inappwebview_linux] HeadlessInAppWebView loadInitialContent no initial content id=%s\n", id_.c_str());
  }
  std::fprintf(stderr, "[flutter_inappwebview_linux] HeadlessInAppWebView loadInitialContent done id=%s\n", id_.c_str());
}

void HeadlessInAppWebView::dispose() {
  // Remove this headless webview from the manager
  // This will trigger the destructor
  if (manager_) {
    manager_->RemoveHeadlessWebView(id_);
  }
}

}  // namespace flutter_inappwebview_plugin
