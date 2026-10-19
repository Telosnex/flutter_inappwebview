#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_ORIGIN_UTIL_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_ORIGIN_UTIL_H_

#include <wpe/webkit.h>

#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <vector>

namespace flutter_inappwebview_plugin {

// "scheme://host[:port]" of a URL, as the browser defines it. Userinfo,
// path and query are not part of it. Empty for URLs with no origin.
inline std::string OriginOfUrl(const std::string& url) {
  WebKitSecurityOrigin* origin = webkit_security_origin_new_for_uri(url.c_str());
  if (origin == nullptr) return "";
  gchar* str = webkit_security_origin_to_string(origin);
  std::string result = str != nullptr ? str : "";
  g_free(str);
  webkit_security_origin_unref(origin);
  return result;
}

// A JS string literal for any text: quotes, backslashes and line breaks
// are escaped.
inline std::string JsStringLiteral(const std::string& text) {
  std::string out =
      nlohmann::json(text).dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
  // JSON allows U+2028 and U+2029 in strings; older JS does not.
  for (const char* sep : {"\xE2\x80\xA8", "\xE2\x80\xA9"}) {
    size_t pos = 0;
    while ((pos = out.find(sep, pos)) != std::string::npos) {
      out.replace(pos, 3, sep[2] == '\xA8' ? "\\u2028" : "\\u2029");
    }
  }
  return out;
}

// A JS condition that is true when the document's origin is one of
// [rules] (N1). nullopt means no restriction: no rules, or a "*" rule.
// Each rule is an exact origin, "scheme://host[:port]", as for
// javaScriptHandlersOriginAllowList (S1). A rule that is not a URL with an
// origin matches nothing. An empty list gives "false".
//
// The condition reads window.location.origin and compares with ===. Page JS
// cannot replace window, location or its origin, so a document-end script
// gets the same result as a document-start script.
inline std::optional<std::string> OriginCheckJs(
    const std::optional<std::vector<std::string>>& rules) {
  if (!rules.has_value()) return std::nullopt;
  std::string condition;
  for (const auto& rule : rules.value()) {
    if (rule == "*") return std::nullopt;
    std::string origin = OriginOfUrl(rule);
    if (origin.empty() || origin == "null") continue;
    if (!condition.empty()) condition += " || ";
    condition += "window.location.origin === " + JsStringLiteral(origin);
  }
  return condition.empty() ? std::string("false") : "(" + condition + ")";
}

}  // namespace flutter_inappwebview_plugin

#endif  // FLUTTER_INAPPWEBVIEW_PLUGIN_ORIGIN_UTIL_H_
