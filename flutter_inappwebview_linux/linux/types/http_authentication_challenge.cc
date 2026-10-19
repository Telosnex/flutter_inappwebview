#include "http_authentication_challenge.h"

#include "../utils/flutter.h"

namespace flutter_inappwebview_plugin {

HttpAuthenticationChallenge::HttpAuthenticationChallenge(const URLProtectionSpace& protectionSpace,
                                                         bool isRetry)
    : protectionSpace(protectionSpace), isRetry(isRetry) {}

FlValue* HttpAuthenticationChallenge::toFlValue() const {
  return to_fl_map({
      {"protectionSpace", protectionSpace.toFlValue()},
      // Dart requires an int. WebKit reports only whether this is a retry.
      {"previousFailureCount", make_fl_value(static_cast<int64_t>(isRetry ? 1 : 0))},
      {"proposedCredential", make_fl_value()},
      {"failureResponse", make_fl_value()},
      {"error", make_fl_value()},
  });
}

}  // namespace flutter_inappwebview_plugin
