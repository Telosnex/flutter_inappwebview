#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_BRIDGE_JS_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_BRIDGE_JS_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "../types/plugin_script.h"
#include "../utils/string.h"

namespace flutter_inappwebview_plugin {

// Forward declaration to avoid circular dependency
class WindowIdJS;

/**
 * JavaScript bridge for communication between web content and native code.
 *
 * This implementation matches iOS JavaScriptBridgeJS.swift for consistency.
 * It uses webkit.messageHandlers to communicate with native code and includes
 * support for multi-window scenarios via _windowId.
 */
class JavaScriptBridgeJS {
 public:
  static void set_JAVASCRIPT_BRIDGE_NAME(const std::string& bridgeName) {
    _JAVASCRIPT_BRIDGE_NAME = bridgeName;
  }

  static std::string get_JAVASCRIPT_BRIDGE_NAME() { return _JAVASCRIPT_BRIDGE_NAME; }

  inline static const std::string JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT_GROUP_NAME =
      "IN_APP_WEBVIEW_JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT";

  inline static const std::string VAR_JAVASCRIPT_BRIDGE_BRIDGE_SECRET =
      "$IN_APP_WEBVIEW_JAVASCRIPT_BRIDGE_BRIDGE_SECRET";

  /**
   * Returns the JavaScript variable name for the window ID.
   * Match iOS WindowIdJS: "window._flutter_inappwebview_windowId"
   */
  static std::string WINDOW_ID_VARIABLE_JS_SOURCE() {
    return "window._" + get_JAVASCRIPT_BRIDGE_NAME() + "_windowId";
  }

  /**
   * JavaScript source code for the bridge.
   * This code sets up window.flutter_inappwebview.callHandler() function
   * which communicates with native code via webkit.messageHandlers.
   *
   * Matches iOS JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_JS_SOURCE()
   */
  static std::string JAVASCRIPT_BRIDGE_JS_SOURCE() {
    return R"JS(
window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS( = {};
window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS(._webMessageChannels = {};
(function(window) {
  var bridgeSecret = ')JS" +
           VAR_JAVASCRIPT_BRIDGE_BRIDGE_SECRET + R"JS(';
  var _JSON_stringify;
  var _Array_slice;
  var _UserMessageHandler;
  var _postMessage;
  
  try {
    _JSON_stringify = window.JSON.stringify;
    _Array_slice = window.Array.prototype.slice;
    _Array_slice.call = window.Function.prototype.call;
    _UserMessageHandler = window.webkit.messageHandlers['callHandler'];
    _postMessage = _UserMessageHandler.postMessage;
    _postMessage.call = window.Function.prototype.call;
  } catch (_) { return; }
  
  window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS(.callHandler = function() {
    var _windowId = )JS" +
           WINDOW_ID_VARIABLE_JS_SOURCE() + R"JS(;
    // Use with_reply API - postMessage returns a Promise directly
    return _postMessage.call(_UserMessageHandler, {
      'handlerName': arguments[0],
      '_bridgeSecret': bridgeSecret,
      'args': _JSON_stringify(_Array_slice.call(arguments, 1)),
      '_windowId': _windowId,
      '_isMainFrame': (window.top === window)
    });
  };
})(window);
)JS";
  }

  /**
   * Defines a function that only plugin scripts can call. It sends internal
   * events (console, dialogs, cursor, ...) with a second secret. Page JS
   * cannot call it: its name is a random global lexical binding, which is
   * not a window property and cannot be enumerated.
   */
  static std::string INTERNAL_CALL_JS_SOURCE(const std::string& functionName,
                                             const std::string& bridgeSecret,
                                             const std::string& internalSecret) {
    return "const " + functionName + R"JS( = (function(window) {
  try {
    var stringify = window.JSON.stringify;
    var slice = window.Array.prototype.slice;
    var apply = window.Reflect.apply;
    var handler = window.webkit.messageHandlers['callHandler'];
    var post = handler.postMessage;
    return function() {
      var _windowId = )JS" + WINDOW_ID_VARIABLE_JS_SOURCE() + R"JS(;
      return apply(post, handler, [{
        'handlerName': arguments[0],
        '_bridgeSecret': ')JS" + bridgeSecret + R"JS(',
        '_internalSecret': ')JS" + internalSecret + R"JS(',
        'args': stringify(apply(slice, arguments, [1])),
        '_windowId': _windowId,
        '_isMainFrame': (window.top === window)
      }]);
    };
  } catch (_) {
    return function() { return Promise.resolve(null); };
  }
})(window);
)JS";
  }

  /**
   * Rewrites calls in a plugin script source to the internal call function.
   * The source is wrapped in a function that gets the internal function as a
   * parameter, so no function that page JS can reach (and print with
   * toString) contains its name.
   */
  static std::string INTERNALIZE_CALLS(std::string source, const std::string& functionName) {
    static const std::string kLocal = "__fiwCall";
    bool found = false;
    for (const std::string& from : {"window." + get_JAVASCRIPT_BRIDGE_NAME() + ".callHandler(",
                                    get_JAVASCRIPT_BRIDGE_NAME() + ".callHandler(",
                                    std::string("bridge.callHandler(")}) {
      size_t pos = 0;
      while ((pos = source.find(from, pos)) != std::string::npos) {
        source.replace(pos, from.size(), kLocal + "(");
        pos += kLocal.size() + 1;
        found = true;
      }
    }
    if (!found) {
      return source;
    }
    return "(function(" + kLocal + ") {\n" + source + "\n})(typeof " + functionName +
           " === 'function' ? " + functionName + " : function() { return Promise.resolve(null); });\n";
  }

  /**
   * JavaScript to dispatch the platform ready event.
   */
  static std::string PLATFORM_READY_JS_SOURCE() {
    return R"JS(
(function() {
  if ((window.top == null || window.top === window) && 
      window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS( != null && 
      window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS(._platformReady == null) {
    window.dispatchEvent(new Event('flutterInAppWebViewPlatformReady'));
    window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS(._platformReady = true;
  }
})();
)JS";
  }

  /**
   * Creates a PluginScript for the JavaScript bridge.
   */
  static std::unique_ptr<PluginScript> JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT(
      const std::string& expectedBridgeSecret,
      const std::optional<std::vector<std::string>>& allowedOriginRules, bool forMainFrameOnly) {
    std::string source = JAVASCRIPT_BRIDGE_JS_SOURCE();
    // Replace the placeholder with the actual secret
    size_t pos = source.find(VAR_JAVASCRIPT_BRIDGE_BRIDGE_SECRET);
    if (pos != std::string::npos) {
      source.replace(pos, VAR_JAVASCRIPT_BRIDGE_BRIDGE_SECRET.length(), expectedBridgeSecret);
    }

    return std::make_unique<PluginScript>(
        JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT_GROUP_NAME, source,
        UserScriptInjectionTime::atDocumentStart, forMainFrameOnly, allowedOriginRules,
        nullptr,                                 // contentWorld
        true,                                    // requiredInAllContentWorlds
        std::vector<std::string>{"callHandler"}  // messageHandlerNames
    );
  }

 private:
  inline static std::string _JAVASCRIPT_BRIDGE_NAME = "flutter_inappwebview";
};

}  // namespace flutter_inappwebview_plugin

#endif  // FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_BRIDGE_JS_H_
