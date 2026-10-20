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

// One origin allow-list rule, in Android's format:
//  - "*": every origin.
//  - "scheme://host[:port]": exactly that origin.
//  - "scheme://*.domain[:port]": every subdomain of domain, at any depth,
//    with that scheme and port. Not domain itself.
// A port that is the scheme's default is the same as no port. A rule that is
// not one of these matches nothing.
struct OriginRule {
  bool any = false;
  std::string exact;   // Normalized origin of an exact rule.
  std::string prefix;  // Subdomain rule: "scheme://".
  std::string suffix;  // Subdomain rule: ".domain[:port]".
};

inline OriginRule ParseOriginRule(const std::string& rule) {
  OriginRule result;
  if (rule == "*") {
    result.any = true;
    return result;
  }
  size_t sep = rule.find("://");
  if (sep != std::string::npos && rule.compare(sep + 3, 2, "*.") == 0) {
    // Normalize with a placeholder label in place of "*".
    static const std::string kLabel = "fiw-subdomain-rule";
    std::string origin = OriginOfUrl(rule.substr(0, sep + 3) + kLabel + rule.substr(sep + 4));
    size_t originSep = origin.find("://");
    if (originSep == std::string::npos || origin.compare(originSep + 3, kLabel.size(), kLabel) != 0) {
      return result;
    }
    result.prefix = origin.substr(0, originSep + 3);
    result.suffix = origin.substr(originSep + 3 + kLabel.size());
    return result;
  }
  std::string origin = OriginOfUrl(rule);
  if (!origin.empty() && origin != "null") {
    result.exact = origin;
  }
  return result;
}

inline bool OriginMatchesRule(const std::string& origin, const OriginRule& rule) {
  if (rule.any) return true;
  if (origin.empty() || origin == "null") return false;
  if (!rule.exact.empty()) return origin == rule.exact;
  if (rule.prefix.empty()) return false;
  // A non-empty subdomain between the prefix and the suffix. The suffix
  // starts with "." and a host has no ":" or "/", so the part between is
  // whole labels of the host.
  return origin.size() > rule.prefix.size() + rule.suffix.size() &&
         origin.compare(0, rule.prefix.size(), rule.prefix) == 0 &&
         origin.compare(origin.size() - rule.suffix.size(), rule.suffix.size(), rule.suffix) == 0;
}

// True when [origin] matches one of [rules]. An empty list allows nothing.
inline bool OriginAllowed(const std::string& origin, const std::vector<std::string>& rules) {
  for (const auto& rule : rules) {
    if (OriginMatchesRule(origin, ParseOriginRule(rule))) return true;
  }
  return false;
}

// A JS condition that is true when the document's origin matches one of
// [rules] (N1), with the same rules as OriginAllowed. nullopt means no
// restriction: no list, or a "*" rule. "false" means no origin matches.
//
// The condition uses only window.location.origin, ===, string length and
// string indexing. Page JS cannot change any of them, so a document-end
// script gets the same result as a document-start script.
inline std::optional<std::string> OriginCheckJs(
    const std::optional<std::vector<std::string>>& rules) {
  if (!rules.has_value()) return std::nullopt;
  std::string exact;
  std::string subdomain;
  for (const auto& text : rules.value()) {
    OriginRule rule = ParseOriginRule(text);
    if (rule.any) return std::nullopt;
    if (!rule.exact.empty()) {
      exact += (exact.empty() ? "" : " || ") + std::string("o === ") + JsStringLiteral(rule.exact);
    } else if (!rule.prefix.empty()) {
      subdomain += (subdomain.empty() ? "" : " || ") + std::string("sub(") +
                   JsStringLiteral(rule.prefix) + ", " + JsStringLiteral(rule.suffix) + ")";
    }
  }
  if (exact.empty() && subdomain.empty()) return std::string("false");
  std::string body = exact.empty() ? subdomain : subdomain.empty() ? exact : exact + " || " + subdomain;
  return "(function(o) {"
         " function sub(p, s) {"
         " if (o.length <= p.length + s.length) return false;"
         " for (var i = 0; i < p.length; i++) if (o[i] !== p[i]) return false;"
         " for (var j = 1; j <= s.length; j++) if (o[o.length - j] !== s[s.length - j]) return false;"
         " return true; }"
         " return " + body + "; })(window.location.origin)";
}

}  // namespace flutter_inappwebview_plugin

#endif  // FLUTTER_INAPPWEBVIEW_PLUGIN_ORIGIN_UTIL_H_
