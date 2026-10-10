// Loads a page with the headless WPEPlatform and runs JavaScript in it. A
// pass shows that WebKit started WPEWebProcess and WPENetworkProcess from
// the SDK that the test links, at whatever path it is extracted to.
//
// Prints the helper path that WebKit used, from /proc of the web process.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wpe/webkit.h>
#include <wpe/headless/wpe-headless.h>

static GMainLoop* loop;
static int status = 1;

static void on_result(GObject* object, GAsyncResult* result, gpointer data) {
  GError* error = NULL;
  JSCValue* value =
      webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object), result, &error);
  if (!value) {
    fprintf(stderr, "JavaScript failed: %s\n", error->message);
  } else {
    char* text = jsc_value_to_string(value);
    printf("JavaScript result: %s\n", text);
    if (strcmp(text, "relocated-42") == 0) status = 0;
    g_free(text);
    g_object_unref(value);
  }
  g_main_loop_quit(loop);
}

static int parent_of(const char* pid) {
  char* path = g_strdup_printf("/proc/%s/stat", pid);
  char* stat = NULL;
  int parent = 0;
  if (g_file_get_contents(path, &stat, NULL, NULL)) {
    const char* end = strrchr(stat, ')');
    if (!end || sscanf(end + 2, "%*c %d", &parent) != 1) parent = 0;
  }
  g_free(stat);
  g_free(path);
  return parent;
}

static gboolean descends_from_us(const char* pid) {
  char current[32];
  g_strlcpy(current, pid, sizeof current);
  for (int depth = 0; depth < 8; depth++) {
    int parent = parent_of(current);
    if (parent <= 1) return FALSE;
    if (parent == getpid()) return TRUE;
    g_snprintf(current, sizeof current, "%d", parent);
  }
  return FALSE;
}

// Prints the executable of each process that descends from this process.
// The web process runs inside bubblewrap, so it is a grandchild.
static void print_helpers(void) {
  GDir* proc = g_dir_open("/proc", 0, NULL);
  const char* name;
  while ((name = g_dir_read_name(proc))) {
    if (!g_ascii_isdigit(name[0]) || !descends_from_us(name)) continue;
    char* exe_path = g_strdup_printf("/proc/%s/exe", name);
    char* exe = g_file_read_link(exe_path, NULL);
    if (exe) printf("Helper: %s\n", exe);
    g_free(exe);
    g_free(exe_path);
  }
  g_dir_close(proc);
}

static void on_load_changed(WebKitWebView* view, WebKitLoadEvent event, gpointer data) {
  if (event != WEBKIT_LOAD_FINISHED) return;
  print_helpers();
  webkit_web_view_evaluate_javascript(view, "document.body.dataset.v + '-' + (6 * 7)", -1,
                                      NULL, NULL, NULL, on_result, NULL);
}

static gboolean on_timeout(gpointer data) {
  fprintf(stderr, "Timed out.\n");
  g_main_loop_quit(loop);
  return G_SOURCE_REMOVE;
}

int main(void) {
  loop = g_main_loop_new(NULL, FALSE);
  WPEDisplay* display = wpe_display_headless_new();
  GError* error = NULL;
  if (!wpe_display_connect(display, &error)) {
    fprintf(stderr, "Display failed: %s\n", error->message);
    return 1;
  }
  WebKitWebView* view = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", display, NULL));
  g_signal_connect(view, "load-changed", G_CALLBACK(on_load_changed), NULL);
  webkit_web_view_load_html(view, "<body data-v='relocated'>ok</body>", "about:blank");
  g_timeout_add_seconds(60, on_timeout, NULL);
  g_main_loop_run(loop);
  g_object_unref(view);
  g_object_unref(display);
  printf(status == 0 ? "PASS\n" : "FAIL\n");
  return status;
}
