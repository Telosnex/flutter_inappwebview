#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_WEB_STORAGE_MANAGER_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_WEB_STORAGE_MANAGER_H_

#include <flutter/method_channel.h>
#include <flutter/standard_message_codec.h>
#include <functional>
#include <string>
#include <vector>

#include "flutter_inappwebview_windows_plugin.h"
#include "types/channel_delegate.h"
#include "webview_environment/webview_environment_manager.h"

namespace flutter_inappwebview_plugin
{
  // Clears website data through the WebView2 profile of a WebViewEnvironment
  // (ICoreWebView2Profile2::ClearBrowsingData*). Uses a temporary hidden
  // WebView2 to reach the profile, so it works when no WebView is open.
  class WebStorageManager : public ChannelDelegate
  {
  public:
    static inline const std::string METHOD_CHANNEL_NAME = "com.pichillilorenzo/flutter_inappwebview_webstoragemanager";

    const FlutterInappwebviewWindowsPlugin* plugin;

    WebStorageManager(const FlutterInappwebviewWindowsPlugin* plugin);
    ~WebStorageManager();

    void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    // [timestampMs] is milliseconds since the Unix epoch; data modified at or
    // after it is removed. Calls [completionHandler] with true on success.
    void removeDataModifiedSince(WebViewEnvironment* webViewEnvironment, const std::vector<std::string>& dataTypes, const int64_t& timestampMs, std::function<void(const bool&)> completionHandler) const;
  };
}

#endif //FLUTTER_INAPPWEBVIEW_PLUGIN_WEB_STORAGE_MANAGER_H_
