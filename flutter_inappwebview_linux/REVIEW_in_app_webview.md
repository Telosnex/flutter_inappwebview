# Review: `linux/in_app_webview/in_app_webview.cc`

Pin `4ff1c5407` (the commit Telosnex uses). Whole file read (8,148 lines),
plus the parts of `in_app_webview.h`, `user_content_controller.cc`,
`content_blocker_handler.cc`, `webview_channel_delegate.cc`,
`base_callback_result.h`, `inappwebview_egl_texture.cc`, `simd_convert.h` and
`javascript_bridge_js.h` needed to confirm findings. 2026-10-18.

Tests: `example/integration_test/lifetime_review_test.dart` (header lists
status). Run on Ubuntu 26.04 arm64, real Plasma session, cached WPE SDK
`2ceafc2f`, **legacy FDO backend** (the backend the shipped Telosnex Snap uses:
it links `libWPEBackend-fdo`, no WPEPlatform symbols). The existing
`headless_regression_test.dart` passed 3/3 in the same setup.

Labels: **Reproduced** = a test shows it. **Confirmed** = traced in code
end to end. **Likely** = strong reading, not proven.

## 1. Crashes

| # | What | Status |
|---|---|---|
| C1 | **The Telosnex abort.** Legacy FDO: the exportable gets a raw `InAppWebView*` as client data and is destroyed only when WebKit frees the backend. `~InAppWebView` only unrefs the `WebKitWebView`; anything else holding a ref (a pending `evaluate_javascript`/`call_async_javascript_function` GTask, WebKit internals) keeps it alive. The next frame runs `wpe_export_shm_buffer_callback` → `OnExportShmBuffer` on freed memory. The same raw pointer goes to the fullscreen and pointer-lock handlers. | **Reproduced (KI-1)** first round. Trace: `wl_surface` commit → WPEBackend-fdo → `wpe_export_shm_buffer_callback` → `OnExportShmBuffer` → `..._dispatch_release_shm_exported_buffer` → SIGSEGV, right after "dealloc InAppWebView". Same frames as the Telosnex x6 abort. |
| C2 | **Page JS kills the host app.** Internal bridge handlers are callable from page JS (the `callHandler` closure adds the secret; no reserved-name check). `onWebMessagePortMessageReceived` / `onWebMessageListenerPostMessageReceived` call `byte.get<int>()` on page data; only `json::parse_error` is caught, so a `type_error` escapes a GSignal callback → `std::terminate`. | **Reproduced (X-1)**: "terminate called after throwing ... type_error.302", SIGABRT. |
| C3 | **Any download crashes** with `useOnDownloadStart`. No `decide-destination` handler, so WebKit saves the file to `~/Downloads` about 2 ms after `download-started`; when Dart answers, the plugin calls `webkit_download_cancel` on the finished download → SIGSEGV in WebKit. Also means "cancel" never works: the file is already written. One view is enough. | **Reproduced (X-5)**; diagnostic run logged finish (2 ms) before cancel. |
| C4 | Every `self` / `&self->pending_*` capture in a channel callback runs after dispose: Flutter answers every platform message (null or not-implemented once the Dart handler is gone), and the callbacks have no cancellable. Navigation and response policy, script dialogs, permissions, auth, file chooser, TLS, create-window, JS handler replies, `getSelectedText` users, `createWebMessageChannel`. | Confirmed (channel delegate code). |
| C5 | `UserContentController` connects `script-message-with-reply-received::callHandler` with raw `this` and never disconnects. Popup views share the parent's content manager: the child's destructor strips the parent's scripts and handler registration, and leaves a dangling handler; while both live, one message is answered twice. | Confirmed. |
| C6 | `ContentBlockerHandler` async compile holds the raw handler (no cancellable); dispose before it finishes → use after free, then initial content is loaded on a freed view. | Confirmed. |
| C7 | Custom schemes register on the shared `WebKitWebContext` with raw `this`; the last view wins, and disposing it leaves a dangling handler. | **Reproduced as broken (X-4)**: a second view's scheme request returns null. No crash seen in that run. |
| C8 | GTK color, date and file dialogs keep the raw view; the destructor never closes them (the hide functions refuse within 200 ms of showing, and the color one is a no-op). Answer the dialog after dispose → use after free. | Confirmed. |
| C9 | `loadData`/`loadFile`/`postUrl`/`reloadFromOrigin` (also called from the constructor) spin `while (g_main_context_iteration(NULL, FALSE))`. Any pending event runs inside a method call, including dispose of this same view, then the code continues on `this`. `pasteFromClipboard` does the same through `gtk_clipboard_wait_for_text`. | Confirmed (re-entrancy); crash not reproduced. |
| C10 | `OnLoadFailedWithTlsErrors` reads `failing_uri` (valid only during the signal) in the async proceed callback. `postUrl` uses a raw `this` in a 100 ms timeout. `SetOnFrameAvailable` passes an unreferenced `WPEToplevel*` to an idle. | Confirmed. |
| C11 | EGL: `GetCurrentEglImage` returns the image handle after dropping the lock; the texture binds it later on the raster thread while the main thread may destroy it on the next frame. Not the shipped path (SHM copy on this VM). | Confirmed by reading both files. |

## 2. Security

| # | What | Status |
|---|---|---|
| S1 | `javaScriptHandlersOriginAllowList` is a substring match on "scheme://host[:port]". `https://example.com` admits `https://example.com.evil.test` and `https://example.com@evil.test`. | **Reproduced (X-3).** |
| S2 | Page JS can spoof internal events (console messages, load-resource, print, ...) by calling internal handler names. | **Reproduced (X-2).** |
| S3 | `_windowId` comes from a page-writable global and picks the target view: a page can route bridge events into another window's Dart side. | Confirmed by reading. |
| S4 | Origin is the top-level page, not the sending frame; `_isMainFrame` comes from the message body. Iframe permission requests are attributed to the top page. | Confirmed. |
| S5 | Page JS can open native GTK color and date dialogs with no user gesture (`_onColorInputClicked` / `_onDateInputClicked`). | Confirmed. |
| S6 | `OnExportShmBuffer` trusts the web process's stride and size (stride < width*4 → out-of-bounds read in the UI process). | Confirmed by reading. |
| S7 | Bridge secret from `mt19937` seeded once by `random_device`: 2^32 possible secrets. | Confirmed by reading. |
| S8 | URL and CSS injection helpers splice values into JS strings with incomplete escaping. | Confirmed by reading. |

## 3. Wrong behavior

- Custom and stock context-menu items share one id space: a custom item with id 1 also opens the link, 10 goes back, 13 reloads (Confirmed).
- `download-started` is connected on the shared network session by every view, so every view's handler runs for every download; a view with downloads off cancels others' (Confirmed; the crash in C3 happens even with one view).
- JS `alert` handled by the client is never closed: `alert()` never returns (Likely; check the Dart contract).
- `<input type=week>` uses the calendar year with the ISO week (wrong at year edges) (Confirmed).
- `loadUrl(URLRequest)` drops method and body; `postUrl` corrupts bytes ≥ 0x80 and forces form-urlencoded; `loadFile` does not percent-encode the path (Confirmed).
- `shouldOverrideUrlLoading`/`onLoadError` always report GET and guess main frame; cancellations are reported as errors (Confirmed).
- `setSettings` ignores runtime changes to bridge and interception settings (Confirmed).
- Ctrl+C/X/V/A/Z/Y key-downs are swallowed and replaced with editing commands; Shift and non-Latin layouts do not match (Confirmed; check what keysym Dart sends).
- `takeScreenshot` feeds straight RGBA to premultiplied Cairo, and has no pixels in zero-copy EGL mode (Confirmed by reading).
- `incognito` leaks one ephemeral network session per view; `getCopyBackForwardList` leaks two lists; context-menu downloads leak; date dialogs leak their context (Confirmed).

## 4. Fix plan for C1 (the Telosnex crash)

1. Give the WPE callbacks a small heap handle (`struct Link { InAppWebView* view; }`) instead of `this`; the destructor sets `view = nullptr`, and the backend's destroy-notify frees the handle. With `view == nullptr` the export callbacks release the buffer and dispatch frame-complete, then return; the fullscreen and pointer-lock handlers ignore the request.
2. Own a `GCancellable` per view; pass it to `evaluate_javascript` / `call_async_javascript_function` and cancel it in the destructor (shortens the window, does not replace step 1).
3. Same handle approach for C4 (channel callbacks), C5, C6, C7 and C8 in follow-ups; C2 and C3 are small, separate fixes.

KI-1 is the red test for step 1. It should pass after the fix, with the rest of the file unchanged.
