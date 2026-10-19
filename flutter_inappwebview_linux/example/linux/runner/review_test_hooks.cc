#include "review_test_hooks.h"

#include <gtk/gtk.h>

#include <dlfcn.h>

#include <cstring>
#include <string>
#include <vector>

namespace {

// Visible plugin dialogs: every visible toplevel that is a GtkDialog.
// The plugin's color chooser and file chooser are dialogs; the date picker
// is gtk_dialog_new_with_buttons.
GList* VisibleDialogs() {
  GList* result = nullptr;
  GList* toplevels = gtk_window_list_toplevels();
  for (GList* l = toplevels; l != nullptr; l = l->next) {
    GtkWidget* w = GTK_WIDGET(l->data);
    if (GTK_IS_DIALOG(w) && gtk_widget_get_visible(w)) {
      result = g_list_prepend(result, w);
    }
  }
  g_list_free(toplevels);
  return result;
}

const char* DialogKind(GtkWidget* dialog) {
  if (GTK_IS_COLOR_CHOOSER_DIALOG(dialog)) return "color";
  if (GTK_IS_FILE_CHOOSER_DIALOG(dialog)) return "file";
  return "other";
}

void FindCalendar(GtkWidget* widget, gpointer out) {
  if (*static_cast<GtkWidget**>(out) != nullptr) return;
  if (GTK_IS_CALENDAR(widget)) {
    *static_cast<GtkWidget**>(out) = widget;
    return;
  }
  if (GTK_IS_CONTAINER(widget)) {
    gtk_container_forall(GTK_CONTAINER(widget), FindCalendar, out);
  }
}

// The custom popup menus are GTK_WINDOW_POPUP windows holding one
// GtkDrawingArea. Returns the drawing area of the first visible one.
GtkWidget* VisiblePopupArea() {
  GtkWidget* found = nullptr;
  GList* toplevels = gtk_window_list_toplevels();
  for (GList* l = toplevels; l != nullptr && found == nullptr; l = l->next) {
    GtkWidget* w = GTK_WIDGET(l->data);
    if (!GTK_IS_WINDOW(w) || !gtk_widget_get_visible(w)) continue;
    if (gtk_window_get_window_type(GTK_WINDOW(w)) != GTK_WINDOW_POPUP) continue;
    GtkWidget* child = gtk_bin_get_child(GTK_BIN(w));
    if (child != nullptr && GTK_IS_DRAWING_AREA(child)) found = child;
  }
  g_list_free(toplevels);
  return found;
}

// Sends a real press+release at (x, y) in the drawing area, so the popup's
// own handlers pick the item (same path as a user click).
bool ClickPopupAt(int x, int y) {
  GtkWidget* area = VisiblePopupArea();
  if (area == nullptr) return false;
  GdkWindow* window = gtk_widget_get_window(area);
  if (window == nullptr) return false;
  GdkDisplay* display = gdk_window_get_display(window);
  GdkSeat* seat = gdk_display_get_default_seat(display);
  GdkDevice* pointer = seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;
  int origin_x = 0, origin_y = 0;
  gdk_window_get_origin(window, &origin_x, &origin_y);
  for (GdkEventType type : {GDK_BUTTON_PRESS, GDK_BUTTON_RELEASE}) {
    GdkEvent* event = gdk_event_new(type);
    event->button.window = GDK_WINDOW(g_object_ref(window));
    event->button.send_event = TRUE;
    event->button.time = GDK_CURRENT_TIME;
    event->button.x = x;
    event->button.y = y;
    event->button.x_root = origin_x + x;
    event->button.y_root = origin_y + y;
    event->button.button = 1;
    if (pointer != nullptr) gdk_event_set_device(event, pointer);
    gtk_main_do_event(event);
    gdk_event_free(event);
  }
  return true;
}

// Live-instance counting. Distro GLib is built without G_ENABLE_DEBUG,
// so g_type_get_instance_count() is always 0. Instead, wrap the class's
// constructed/finalize methods at startup, before any instance exists.
struct CountedType {
  const char* name;
  const char* get_type_symbol;
  GType type = 0;
  void (*orig_constructed)(GObject*) = nullptr;
  void (*orig_finalize)(GObject*) = nullptr;
  int64_t live = 0;
  int64_t created = 0;
};

std::vector<CountedType>& Counted() {
  static std::vector<CountedType> types = {
      {"WebKitWebView", "webkit_web_view_get_type"},
      {"WebKitNetworkSession", "webkit_network_session_get_type"},
      {"WebKitDownload", "webkit_download_get_type"},
      {"WebKitUserContentManager", "webkit_user_content_manager_get_type"},
  };
  return types;
}

// The counted types are unrelated, so at most one is an ancestor of (or
// equal to) the object's type. Subclass instances reach these methods
// through their parent chain: count them too, and always chain up.
CountedType* FindCounted(GObject* object) {
  for (auto& t : Counted()) {
    if (t.type != 0 && g_type_is_a(G_OBJECT_TYPE(object), t.type)) return &t;
  }
  return nullptr;
}

void CountedConstructed(GObject* object) {
  CountedType* t = FindCounted(object);
  t->live++;
  t->created++;
  if (t->orig_constructed != nullptr) t->orig_constructed(object);
}

void CountedFinalize(GObject* object) {
  CountedType* t = FindCounted(object);
  t->live--;
  t->orig_finalize(object);
}

void InstallCounters() {
  for (auto& t : Counted()) {
    auto get_type = reinterpret_cast<GType (*)()>(dlsym(RTLD_DEFAULT, t.get_type_symbol));
    if (get_type == nullptr) continue;
    t.type = get_type();
    auto* klass = G_OBJECT_CLASS(g_type_class_ref(t.type));  // kept for the process lifetime
    t.orig_constructed = klass->constructed;
    t.orig_finalize = klass->finalize;
    klass->constructed = CountedConstructed;
    klass->finalize = CountedFinalize;
  }
}

int64_t Count(const std::string& name, bool created) {
  for (auto& t : Counted()) {
    if (name == t.name) return t.type == 0 ? -1 : (created ? t.created : t.live);
  }
  return -1;
}

void Respond(FlMethodCall* call, FlValue* value) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call, response, nullptr);
}

FlValue* Arg(FlMethodCall* call, const char* key) {
  FlValue* args = fl_method_call_get_args(call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  return fl_value_lookup_string(args, key);
}

int64_t IntArg(FlMethodCall* call, const char* key, int64_t fallback) {
  FlValue* v = Arg(call, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_INT ? fl_value_get_int(v) : fallback;
}

std::string StringArg(FlMethodCall* call, const char* key) {
  FlValue* v = Arg(call, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_STRING ? fl_value_get_string(v) : "";
}

void HandleCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);

  if (strcmp(method, "listDialogs") == 0) {
    g_autoptr(FlValue) list = fl_value_new_list();
    GList* dialogs = VisibleDialogs();
    for (GList* l = dialogs; l != nullptr; l = l->next) {
      fl_value_append_take(list, fl_value_new_string(DialogKind(GTK_WIDGET(l->data))));
    }
    g_list_free(dialogs);
    Respond(call, list);
    return;
  }

  // respondDialog {kind, response: "ok"|"cancel", color?: "#rrggbb", path?: file}
  if (strcmp(method, "respondDialog") == 0) {
    std::string kind = StringArg(call, "kind");
    bool ok = StringArg(call, "response") == "ok";
    GtkWidget* target = nullptr;
    GList* dialogs = VisibleDialogs();
    for (GList* l = dialogs; l != nullptr; l = l->next) {
      if (kind.empty() || kind == DialogKind(GTK_WIDGET(l->data))) {
        target = GTK_WIDGET(l->data);
        break;
      }
    }
    g_list_free(dialogs);
    if (target == nullptr) {
      g_autoptr(FlValue) r = fl_value_new_bool(FALSE);
      Respond(call, r);
      return;
    }
    std::string color = StringArg(call, "color");
    if (!color.empty() && GTK_IS_COLOR_CHOOSER(target)) {
      GdkRGBA rgba;
      if (gdk_rgba_parse(&rgba, color.c_str())) {
        gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(target), &rgba);
      }
    }
    std::string path = StringArg(call, "path");
    if (!path.empty() && GTK_IS_FILE_CHOOSER(target)) {
      gtk_file_chooser_set_filename(GTK_FILE_CHOOSER(target), path.c_str());
    }
    // Same signal the dialog emits when the user presses the button.
    gtk_dialog_response(GTK_DIALOG(target), ok ? GTK_RESPONSE_OK : GTK_RESPONSE_CANCEL);
    g_autoptr(FlValue) r = fl_value_new_bool(TRUE);
    Respond(call, r);
    return;
  }

  // setCalendarDate {year, month (1-12), day}: selects a day in the open
  // date dialog's GtkCalendar.
  if (strcmp(method, "setCalendarDate") == 0) {
    GtkWidget* calendar = nullptr;
    GList* dialogs = VisibleDialogs();
    for (GList* l = dialogs; l != nullptr && calendar == nullptr; l = l->next) {
      FindCalendar(GTK_WIDGET(l->data), &calendar);
    }
    g_list_free(dialogs);
    if (calendar != nullptr) {
      gtk_calendar_select_month(GTK_CALENDAR(calendar),
                                static_cast<guint>(IntArg(call, "month", 1) - 1),
                                static_cast<guint>(IntArg(call, "year", 2000)));
      gtk_calendar_select_day(GTK_CALENDAR(calendar), static_cast<guint>(IntArg(call, "day", 1)));
    }
    g_autoptr(FlValue) r = fl_value_new_bool(calendar != nullptr);
    Respond(call, r);
    return;
  }

  if (strcmp(method, "popupVisible") == 0) {
    g_autoptr(FlValue) r = fl_value_new_bool(VisiblePopupArea() != nullptr);
    Respond(call, r);
    return;
  }

  // clickPopupItem {index}: index counts rows top to bottom, separators
  // included, using the popup's own layout constants (padding 8, item 32,
  // separator 9).
  if (strcmp(method, "clickPopupItem") == 0) {
    int64_t index = IntArg(call, "index", 0);
    std::string kinds = StringArg(call, "rows");  // e.g. "iis i": i=item, s=separator
    int y = 8;
    for (int64_t i = 0; i < index && i < static_cast<int64_t>(kinds.size()); i++) {
      y += kinds[i] == 's' ? 9 : 32;
    }
    y += 16;
    g_autoptr(FlValue) r = fl_value_new_bool(ClickPopupAt(20, y));
    Respond(call, r);
    return;
  }

  // instanceCount {type, created?} -> live instances (or, with created,
  // instances ever constructed), or -1 if the type is not counted (see
  // Counted()) or its get_type symbol was not found.
  if (strcmp(method, "instanceCount") == 0) {
    FlValue* created = Arg(call, "created");
    bool want_created = created != nullptr && fl_value_get_type(created) == FL_VALUE_TYPE_BOOL &&
                        fl_value_get_bool(created);
    g_autoptr(FlValue) r = fl_value_new_int(Count(StringArg(call, "type"), want_created));
    Respond(call, r);
    return;
  }

  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void review_test_hooks_register(FlView* view) {
  const gchar* enabled = g_getenv("FLUTTER_INAPPWEBVIEW_REVIEW_HOOKS");
  if (enabled == nullptr || strcmp(enabled, "1") != 0) return;
  InstallCounters();
  FlEngine* engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // Lives for the whole process, like the engine.
  FlMethodChannel* channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(engine), "flutter_inappwebview_example/review_hooks",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, HandleCall, nullptr, nullptr);
}
