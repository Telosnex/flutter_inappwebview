#include <ctime>
#include <WebView2.h>

#include "types/callbacks_complete.h"
#include "utils/flutter.h"
#include "utils/log.h"
#include "utils/timer.h"
#include "web_storage_manager.h"

namespace flutter_inappwebview_plugin
{
  using namespace Microsoft::WRL;

  namespace
  {
    // WebsiteDataType native values that WebView2 can clear, and their kinds.
    // WKWebsiteDataTypeSessionStorage has no kind: WebView2 keeps session
    // storage in memory only, per WebView.
    std::optional<COREWEBVIEW2_BROWSING_DATA_KINDS> toBrowsingDataKind(const std::string& dataType)
    {
      if (dataType == "WKWebsiteDataTypeFetchCache") return COREWEBVIEW2_BROWSING_DATA_KINDS_CACHE_STORAGE;
      if (dataType == "WKWebsiteDataTypeDiskCache") return COREWEBVIEW2_BROWSING_DATA_KINDS_DISK_CACHE;
      if (dataType == "WKWebsiteDataTypeMemoryCache") return COREWEBVIEW2_BROWSING_DATA_KINDS_DISK_CACHE;
      if (dataType == "WKWebsiteDataTypeOfflineWebApplicationCache") return COREWEBVIEW2_BROWSING_DATA_KINDS_DISK_CACHE;
      if (dataType == "WKWebsiteDataTypeCookies") return COREWEBVIEW2_BROWSING_DATA_KINDS_COOKIES;
      if (dataType == "WKWebsiteDataTypeLocalStorage") return COREWEBVIEW2_BROWSING_DATA_KINDS_LOCAL_STORAGE;
      if (dataType == "WKWebsiteDataTypeWebSQLDatabases") return COREWEBVIEW2_BROWSING_DATA_KINDS_WEB_SQL;
      if (dataType == "WKWebsiteDataTypeIndexedDBDatabases") return COREWEBVIEW2_BROWSING_DATA_KINDS_INDEXED_DB;
      if (dataType == "WKWebsiteDataTypeServiceWorkerRegistrations") return COREWEBVIEW2_BROWSING_DATA_KINDS_SERVICE_WORKERS;
      return std::nullopt;
    }

    // Number of WebsiteDataType values (WebsiteDataType.ALL).
    constexpr size_t kAllWebsiteDataTypeCount = 10;
  }

  WebStorageManager::WebStorageManager(const FlutterInappwebviewWindowsPlugin* plugin)
    : plugin(plugin), ChannelDelegate(plugin->registrar->messenger(), WebStorageManager::METHOD_CHANNEL_NAME)
  {}

  void WebStorageManager::HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    auto* argumentsValue = method_call.arguments();
    if (!argumentsValue || !std::holds_alternative<flutter::EncodableMap>(*argumentsValue)) {
      result->Error("0", "Arguments must be a map.");
      return;
    }
    auto arguments = std::get<flutter::EncodableMap>(*argumentsValue);
    auto methodName = method_call.method_name();

    if (!string_equals(methodName, "removeDataModifiedSince")) {
      result->NotImplemented();
      return;
    }
    if (!plugin || !plugin->webViewEnvironmentManager) {
      result->Error("0", "Plugin is not available.");
      return;
    }

    auto webViewEnvironmentId = get_optional_fl_map_value<std::string>(arguments, "webViewEnvironmentId");
    auto webViewEnvironment = webViewEnvironmentId.has_value() && map_contains(plugin->webViewEnvironmentManager->webViewEnvironments, webViewEnvironmentId.value())
      ? plugin->webViewEnvironmentManager->webViewEnvironments.at(webViewEnvironmentId.value()).get() : nullptr;

    auto dataTypes = get_fl_map_value<std::vector<std::string>>(arguments, "dataTypes", std::vector<std::string>{});
    auto timestampMs = get_fl_map_value<int64_t>(arguments, "timestamp");

    auto result_ = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
    auto callback = [this, result_, dataTypes, timestampMs](WebViewEnvironment* webViewEnvironment)
      {
        if (!webViewEnvironment) {
          result_->Error("0", "Cannot obtain the WebViewEnvironment!");
          return;
        }
        removeDataModifiedSince(webViewEnvironment, dataTypes, timestampMs, [result_](const bool& removed)
          {
            if (removed) {
              result_->Success();
            }
            else {
              result_->Error("0", "WebView2 did not clear the browsing data.");
            }
          });
      };

    if (webViewEnvironment) {
      callback(webViewEnvironment);
    }
    else {
      plugin->webViewEnvironmentManager->createOrGetDefaultWebViewEnvironment(callback);
    }
  }

  void WebStorageManager::removeDataModifiedSince(WebViewEnvironment* webViewEnvironment, const std::vector<std::string>& dataTypes, const int64_t& timestampMs, std::function<void(const bool&)> completionHandler) const
  {
    int kinds = 0;
    size_t knownTypes = 0;
    for (const auto& dataType : dataTypes) {
      if (dataType == "WKWebsiteDataTypeSessionStorage") {
        knownTypes++;
      }
      auto kind = toBrowsingDataKind(dataType);
      if (kind.has_value()) {
        kinds |= kind.value();
        knownTypes++;
      }
    }
    // WebsiteDataType.ALL clears the whole profile: also autofill, saved
    // passwords, history and settings.
    const bool allTypes = knownTypes == kAllWebsiteDataTypeCount;
    if (allTypes) {
      kinds = COREWEBVIEW2_BROWSING_DATA_KINDS_ALL_PROFILE;
    }
    if (kinds == 0) {
      completionHandler(true);
      return;
    }
    const bool fromEpoch = timestampMs <= 0;
    // WebView2 takes seconds since the epoch.
    const double startSeconds = fromEpoch ? 0.0 : (double)timestampMs / 1000.0;
    const double endSeconds = (double)time(nullptr) + 60.0;

    webViewEnvironment->useTempWebView([kinds, allTypes, fromEpoch, startSeconds, endSeconds, completionHandler](wil::com_ptr<ICoreWebView2Controller> webViewController, wil::com_ptr<ICoreWebView2> webView)
      {
        auto finish = [completionHandler, webViewController](const bool& ok)
          {
            completionHandler(ok);
            if (webViewController) {
              // Same delay as CookieManager::deleteAllCookies: closing the
              // temporary WebView2 inside its own callback can crash it.
              Timer::setTimeout([webViewController]()
                {
                  webViewController->Close();
                }, 1000);
            }
          };

        auto webView13 = webView ? webView.try_query<ICoreWebView2_13>() : nullptr;
        wil::com_ptr<ICoreWebView2Profile> profile;
        if (!webView13 || failedAndLog(webView13->get_Profile(&profile)) || !profile) {
          finish(false);
          return;
        }
        auto profile2 = profile.try_query<ICoreWebView2Profile2>();
        if (!profile2) {
          finish(false);
          return;
        }

        auto handler = Callback<ICoreWebView2ClearBrowsingDataCompletedHandler>(
          [finish](HRESULT errorCode) -> HRESULT
          {
            finish(succeededOrLog(errorCode));
            return S_OK;
          });
        HRESULT hr = (allTypes && fromEpoch)
          ? profile2->ClearBrowsingDataAll(handler.Get())
          : profile2->ClearBrowsingDataInTimeRange((COREWEBVIEW2_BROWSING_DATA_KINDS)kinds, startSeconds, endSeconds, handler.Get());
        if (failedAndLog(hr)) {
          finish(false);
        }
      });
  }

  WebStorageManager::~WebStorageManager()
  {
    debugLog("dealloc WebStorageManager");
    plugin = nullptr;
  }
}
