#include "js_before_unload_response.h"

#include "../utils/flutter.h"

namespace flutter_inappwebview_plugin {

JsBeforeUnloadResponse::JsBeforeUnloadResponse()
    : handledByClient(false), shouldAllowNavigation(true) {}

JsBeforeUnloadResponse::JsBeforeUnloadResponse(FlValue* map)
    : handledByClient(false), shouldAllowNavigation(true) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return;
  }

  handledByClient = get_fl_map_value(map, "handledByClient", handledByClient);
  // Dart JsBeforeUnloadResponseAction: CONFIRM = 0 (leave), CANCEL = 1 (W3d).
  int64_t actionInt = get_fl_map_value<int64_t>(map, "action", 0);
  shouldAllowNavigation = (actionInt == 0);
  message = get_optional_fl_map_value<std::string>(map, "message");
}

}  // namespace flutter_inappwebview_plugin
