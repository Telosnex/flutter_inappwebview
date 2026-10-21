# Review: `linux/in_app_webview/in_app_webview.cc`

Pin `4ff1c5407` (the commit that Telosnex uses). I read the whole file (8,148 lines). I also read the parts of `in_app_webview.h`, `user_content_controller.cc`, `content_blocker_handler.cc`, `webview_channel_delegate.cc`, `base_callback_result.h`, `inappwebview_egl_texture.cc`, `simd_convert.h`, `javascript_bridge_js.h` and the date and color input scripts that the findings need. Updated 2026-10-19. This file holds all review findings and results. The earlier scratch notes are merged into sections 5 and 6.

## Tests

Each finding has a red test in `example/integration_test/`:

- `review_crash_test.dart`: section 1 (C ids).
- `review_security_test.dart`: section 2 (S ids).
- `review_behavior_test.dart`: section 3 (W ids).
- `review_common.dart`: shared helpers and a local HTTP and HTTPS server.

Each test asserts the correct behavior. On this pin, a red test fails or crashes. After a fix, it passes. Some tests have a precondition. If the precondition fails, the failure message names the finding that blocks it.

The example runner has test-only hooks (`example/linux/runner/review_test_hooks.cc`). The hooks answer the real GTK color, date and file dialogs, click items in the plugin's popup menus, and count live instances of `WebKitWebView`, `WebKitNetworkSession`, `WebKitDownload` and `WebKitUserContentManager`. The hooks are off unless `FLUTTER_INAPPWEBVIEW_REVIEW_HOOKS=1` is set. Tests that need them skip without them.

Setup for all results below: Ubuntu 26.04 arm64, a real Plasma session, the cached WPE SDK `2ceafc2f`, and the legacy FDO backend. The shipped Telosnex Snap uses this backend. It links `libWPEBackend-fdo` and has no WPEPlatform symbols.

### Running the red tests

1. Run one test per process. A native crash stops the whole run.
   `flutter test integration_test/review_crash_test.dart -d linux --plain-name "C4a "`
2. Put a space after the id in `--plain-name`. Without it, `C4` also selects `C4a` to `C4h`.
3. For tests that use the hooks, set `FLUTTER_INAPPWEBVIEW_REVIEW_HOOKS=1` in the environment of `flutter test`.
4. For use-after-free tests, use an AddressSanitizer build. A normal build often survives a use after free. Build with `CFLAGS` and `CXXFLAGS` set to `-fsanitize=address -fno-omit-frame-pointer -g -O1` and `LDFLAGS=-fsanitize=address`.
5. In an ASan run, set `ASAN_OPTIONS=log_path=<dir>/asan`. `flutter test` does not show the stderr of the app, so the report is lost without `log_path`.

Status words:

- **ASan**: the ASan build reports `heap-use-after-free`. The use site and the free site are given.
- **Red**: the test fails or crashes in a normal build.
- **Blocked**: a different finding stops the test before it reaches the code. The blocking finding is named.
- **Not reproduced**: the test passes. The finding stays as a code reading, or is withdrawn.

## 1. Crashes

In every ASan row, the memory was freed by `~HeadlessInAppWebView`, which `dispose` calls, unless the row says otherwise.

| # | What | Test result |
|---|---|---|
| C1 | **The Telosnex abort.** With legacy FDO, the exportable gets a raw `InAppWebView*` as client data. WebKit destroys the exportable only when it frees the backend. `~InAppWebView` only unrefs the `WebKitWebView`. Anything else that holds a reference keeps the view alive, for example a pending `evaluate_javascript` task. The next frame then runs `OnExportShmBuffer` on freed memory. | **ASan** (C1): use in `OnExportShmBuffer`. Red in a normal build. Same frames as the Telosnex abort. |
| C1b | The fullscreen handler gets the same raw pointer. | **ASan** (C1b): use in `OnDomFullscreenRequest`. |
| C1c | The pointer-lock handler gets the same raw pointer. | **ASan** (C1c), but the report shows the C1 frame path. The test does not isolate the pointer-lock path. |
| C2 | **Page JS stops the host app.** Page JS can call internal bridge handlers (see S2). `onWebMessagePortMessageReceived` and `onWebMessageListenerPostMessageReceived` call `byte.get<int>()` on page data. The code catches only `json::parse_error`. A `type_error` leaves a GSignal callback and calls `std::terminate`. | **Red** (C2, C2b): `terminate called after throwing ... type_error.302`, SIGABRT. |
| C3 | **A download crashes the app when `useOnDownloadStart` is on.** There is no `decide-destination` handler. WebKit saves the file to `~/Downloads` about 2 ms after `download-started`. When Dart answers, the plugin calls `webkit_download_cancel` on the finished download, and WebKit crashes. "Cancel" also never works, because the file is already on disk. One view is enough. | **Red** (C3): SIGSEGV in WebKit. |
| C4 | Channel callbacks capture `self` or `&self->pending_*`. Flutter answers every platform message, also after dispose, and the callbacks have no cancellable. So each callback runs on a freed view. | See C4a to C4h. |
| C4a | `shouldOverrideUrlLoading` answer after dispose. | **ASan**: use in the `OnShouldOverrideUrlLoadingDecision` lambda. |
| C4b | `onNavigationResponse` answer after dispose. The lambda reads `self->settings_` only for a MIME type that WebKit cannot show. | **ASan**: use in the `OnDecidePolicy` lambda, from `WebViewChannelDelegate::onNavigationResponse`. Passes in a normal build. |
| C4c | `confirm()` answer after dispose. | **ASan**: use in the `OnScriptDialog` confirm lambda. Red in a normal build. |
| C4d | Permission answer after dispose. | **Blocked** by W18. |
| C4e | HTTP auth answer after dispose. | **Blocked** by W16. |
| C4f | TLS answer after dispose. | **Blocked** by W17. |
| C4g | `onCreateWindow` answer after the opener is disposed. | Not reproduced (normal and ASan). Closed 2026-10-21 (owner): the path barely runs while popups do not work (W19). |
| C4h | `createWebMessageChannel` racing dispose. The completion of the JS call writes `web_message_channels_` through a raw `self`. | **ASan**: write from the `evaluateJavascript` completion. Passes in a normal build. |
| C5 | `UserContentController` connects `script-message-with-reply-received::callHandler` with a raw `this` and never disconnects it. A popup shares the content manager of its opener. When the popup is destroyed, it removes the scripts and the handler of the opener and leaves a dangling handler. | **Blocked** by W19: the popup never gets a bridge. |
| C5b | (Withdrawn.) A handled popup stays in the manager after its opener is disposed. | Not reproduced. The hooks show no leaked `WebKitWebView`. |
| C6 | `ContentBlockerHandler` compiles rules asynchronously and holds a raw handler with no cancellable. Dispose before the compile ends gives a use after free. Then the code loads initial content on the freed view. | **ASan**: read of freed memory at `content_blocker_handler.cc:319` (`handler->filter_store_`). The free stack that ASan prints is inside the WebKit rule compiler, so the report does not show which object was freed. Red in a normal build. |
| C7 | Custom schemes register on the shared `WebKitWebContext` with a raw `this`. The last view to register wins. Dispose of that view leaves a dangling handler. | **Red**: the second view gets `null` instead of its own response. No crash. |
| C8a | The GTK color dialog keeps a raw view. The destructor does not close it. | **ASan**: use in `OnColorDialogResponse`. Red in a normal build. |
| C8b | The date dialog: the same problem through `DateDialogContext`. | **ASan**: use in `OnDateDialogResponse`. Red in a normal build. |
| C8c | The file chooser: the same problem. `HideFileChooser` also refuses to close a dialog less than 200 ms after it opened. | **ASan**: use in `OnFileChooserDialogResponse`. In a normal build, the test fails because the dialog stays open after dispose. |
| C8d | A `<select>` popup that is open when the view is disposed. | **Red**: the app stops when the widget is removed, in both builds, with no ASan report. `C8d-control` does the same steps without the popup and passes. The cause is not known. |
| C9a | `loadData`, `loadFile`, `postUrl` and `reloadFromOrigin` run `while (g_main_context_iteration(NULL, FALSE))`. A dispose of the same view can run inside this loop. Then the method continues on `this`. `pasteFromClipboard` has the same problem through `gtk_clipboard_wait_for_text`. | Not reproduced (normal and ASan). Why: Flutter runs queued platform messages in one batch, and a nested `g_main_context_iteration` does not re-enter that source; the dispose has to arrive while the spin runs. **Fixed 2026-10-21** without a red test: the four spins return when `lifetime_token_` expired (`SpinMainLoopAndCheckAlive`), the two pastes check it after `gtk_clipboard_wait_for_text`, and `HeadlessInAppWebView::loadInitialContent` keeps the web view and id in locals. |
| C9b | `postUrl` uses a raw `this` in a 100 ms timeout. | **ASan**: use in the `postUrl` timeout. Red in a normal build. |
| C10 | `OnLoadFailedWithTlsErrors` reads `failing_uri` in the asynchronous "proceed" callback. That pointer is valid only during the signal. | **Blocked** by W17. |
| C11 | EGL: `GetCurrentEglImage` returns the image handle after it releases the lock. The raster thread binds the image later, and the main thread can destroy it on the next frame. The shipped path on this VM is the SHM copy, not EGL. | No test. Found by reading. Rechecked 2026-10-21: the GL texture is the default whenever GDK has GL; zero-copy EGL import runs only for DMA-BUF buffers, so on GPU hardware, not on this VM (SHM buffers). Worse than first described: `OnBufferRendered` destroys the old EGL image and releases its buffer before the texture gets the new one, so the raster thread can bind a destroyed image; and if EGL import later fails, the texture keeps the destroyed handle. **Fixed 2026-10-21; run on a Raspberry Pi CM5 (V3D) under labwc, all frames DMA-BUF.** Also found: `wpe_buffer_import_to_egl_image` is transfer none (WPEBufferDMABuf caches the image and destroys it in dispose, WebKit 2.54.1), so the plugin destroyed images it did not own; a reused buffer returned the destroyed image. Now a shared frame holds the buffer (never destroys the image) and returns it to WPE on the main thread when the last holder, view or texture, drops it; the texture keeps the frame it bound until it binds another, and re-specifies (not sub-uploads) when it falls back to copied pixels. Legacy FDO path unchanged. |
| C12 | `setSize` sends zero and negative sizes to WPE. | Not reproduced (normal and ASan). Closed 2026-10-21 (owner). |

## 2. Security

| # | What | Test result |
|---|---|---|
| S1 | `javaScriptHandlersOriginAllowList` is a substring match on `scheme://host[:port]`. | **Red**: with the allow list `https://example.com`, these pages reach the handler: `https://example.com.evil.test` (S1), `https://example.com@evil.test` (S1b), `https://example.com:8443` (S1c). `S1-control` passes. |
| S2 | Page JS can fake internal events by calling internal handler names, for example a console message. | **Red**. |
| S3 | `_windowId` comes from a global that the page can write. It selects the target view, so a page can send bridge events to the Dart side of a different window. | Passes now, but only because popups do not work (W19). The test becomes live after W19 is fixed. |
| S4a | The permission origin is the full page URL with path and query, not the origin. | **Blocked** by W18. |
| S4b | A permission request from a cross-origin iframe has the origin of the top page. | **Blocked** by W18. |
| S5 | Page JS can open native GTK color and date dialogs with no user gesture. | **Red**. |
| S6 | `OnExportShmBuffer` trusts the stride and size from the web process. A stride less than `width*4` gives an out-of-bounds read in the UI process. | No test. Found by reading. |
| S7 | The bridge secret comes from `mt19937`, seeded once by `random_device`. There are only 2^32 possible secrets. | No test. Found by reading. |
| S8a | `injectJavascriptFileFromUrl` puts the URL into a JS string with no escaping. A quote in the URL runs page-level code. | **Red**. |
| S8d | `injectCSSFileFromUrl` has the same problem. | **Red**. |
| S9 | No code sets `pointer_lock_handler_`, so `OnPointerLockRequest` accepts every request. | Inconclusive. A real click reaches the page, but neither `pointerlockchange` nor `pointerlockerror` occurs. |

## 3. Wrong behavior

| # | What | Test result |
|---|---|---|
| W1 | Custom and stock context-menu items share one id space. A custom item with id 12 (`WEBKIT_CONTEXT_MENU_ACTION_RELOAD`) also reloads the page. | **Red**: the page loads twice. |
| W1b | The int id of a custom context-menu item returns to Dart as a String. | **Red**: `['4242']`, not `[4242]`. |
| W2a | Every view connects `download-started` on the shared network session. A view with downloads off cancels the downloads of other views. | The test crashes before its check. The test cancels a download, as C3 does, so the crash is probably C3. Retest after C3 is fixed. |
| W3a | An `alert()` that the client handles is never closed, so `alert()` never returns. | **Red**: the page stays blocked. |
| W3b | `confirm()` answers are inverted. Dart `JsConfirmResponseAction` has `CONFIRM=0, CANCEL=1`. The native enum has `CANCEL=0, CONFIRM=1`. | **Red**: CONFIRM gives `false`. |
| W3c | `prompt()` has the same inversion. | **Red**: CONFIRM gives `null`. |
| W3d | The `beforeunload` answer of the client has no effect. | **Red**: the client said "stay", and the page navigated. |
| W4 | `<input type=week>` uses the calendar year with the ISO week. | **Red**: 2024-12-30 gives `2024-W01`, not `2025-W01`. |
| W5a | `loadUrl(URLRequest)` drops the method and the body. | **Red**: the server gets GET. |
| W5b | `postUrl` sends the body through XHR as a JS string. Bytes from 0x80 change to UTF-8. | **Red**: 6 bytes arrive as 9. |
| W5c | `loadFile` does not percent-encode the path. | **Red**: an asset in `review #dir/` does not load. |
| W6a | `shouldOverrideUrlLoading` always reports GET. | **Red** for a form POST. |
| W6b | The main-frame flag is a guess from the target frame name. | **Red**: an unnamed iframe is reported as the main frame. |
| W6c | `stopLoading` is reported as an error. | **Red**: `Load request cancelled`. |
| W7 | `setSettings` ignores a runtime change to `javaScriptBridgeEnabled`. | **Red**: the bridge stays after a reload. |
| W8 | Ctrl+A key-down never reaches the page. The plugin replaces it with an editing command. | **Red**: the page sees `C-Control` and `b`, not `C-a`. |
| W8b | (Withdrawn.) Ctrl+Shift+Z does not redo. | Not reproduced. Redo works. |
| W9 | (Withdrawn.) `takeScreenshot` gives wrong colors for translucent pixels. | Not reproduced. An opaque pixel and a 50% red pixel are both correct. The zero-copy EGL mode still has no screenshot pixels (found by reading). |
| W10 | Each incognito view leaks one ephemeral `WebKitNetworkSession`. | **Red**: 3 views leave 3 live sessions. |
| W11 | `getCopyBackForwardList` reads the back list of WebKit as oldest-first. WebKit gives it nearest-first. | **Red**: `['/two', '/one', '/three']`. |
| W12 | With `javaScriptCanOpenWindowsAutomatically` off, `window.open` loads the popup URL in the current view. | **Red**: the opener navigates away. |
| W13 | A custom-scheme response with an empty body is reported as "not found". | **Red**: `fetch` fails. |
| W15 | (Withdrawn.) Control characters in an error, and a BigInt result, break `evaluateJavascript`. | Not reproduced. |
| W16 | **HTTP auth never works.** Native code sends `previousFailureCount` as null. `HttpAuthenticationChallenge.fromMap` requires an int and throws, so the plugin cancels. `HttpAuthResponseAction` also has no native values for Linux. | **Red**: `onReceivedHttpAuthRequest` never runs, and every 401 page fails. |
| W17 | **TLS errors never reach the app.** Native code sends `SslError.code` as a String. Dart requires an int, so the plugin cancels. | **Red**: `onReceivedServerTrustAuthRequest` never runs. |
| W18 | **Every permission request is denied.** In `flutter_inappwebview_platform_interface` 1.4.0-beta.3, `PermissionResourceType` has native values only for Windows. On Linux, `fromNativeValue` returns null and the event throws. The fix can be in that package or in the values that Linux sends. | **Red**: `onPermissionRequest` never runs, and `Notification.requestPermission()` gives `denied`. |
| W19 | **Popups never work.** `OnCreateWebView` stores the popup by `windowId` in the manager. No code reads `windowId` when Dart creates the popup view. The popup is a new, unrelated, empty view, and `window.open` returns `null` to the page. | **Red**. |
| W21 | (Withdrawn.) A second color picker leaves the first promise unsettled. | Not reproduced. |
| W22 | `callAsyncJavaScript` puts argument keys into `const {...}` without a check. A key that is not a JS identifier is a SyntaxError. | **Red** with the key `my-key`. |
| W23 | `addWebMessageListener` splits an allowed-origin rule at the first `:`, so an IPv6 rule fails. | **Red** with `http://[::1]:<port>`. |
| W24 | A context-menu "Download Linked File" leaks one `WebKitDownload`. `webkit_web_view_download_uri` returns a new reference that the code never releases. | **Red**: one live `WebKitDownload` remains. |
| S8b | (Moved from section 2.) `injectCSSCode` escapes only `'` and `\n`, not `\`. Valid CSS with an escaped quote becomes a JS syntax error, and the CSS is dropped. An offline check showed that this cannot run code: every break-out leaves an unpaired quote. | **Red**: the CSS does not apply. |
| S8c | (Moved from section 2.) CSS with `\r` is a JS syntax error, and the CSS is dropped. | **Red**. |

W14 is withdrawn. It came from a misreading of the listener code.

## 4. Fix plan for C1 (the Telosnex crash)

1. Give the WPE callbacks a small heap handle (`struct Link { InAppWebView* view; }`) instead of `this`. The destructor sets `view = nullptr`. The destroy-notify of the backend frees the handle. When `view == nullptr`, the export callbacks release the buffer, send frame-complete, and return. The fullscreen and pointer-lock handlers ignore the request.
2. Give each view a `GCancellable`. Pass it to `evaluate_javascript` and `call_async_javascript_function`, and cancel it in the destructor. This makes the window shorter. It does not replace step 1.
3. Use the same handle approach in follow-ups for C4, C5, C6, C7, C8 and C9b. C2 and C3 are small, separate fixes.

C1, C1b and C1c are the red tests for steps 1 and 2. They must pass after the fix in the ASan build.

Fix W16, W17, W18 and W19 early. They block C4d, C4e, C4f, C5, C10, S3, S4a and S4b. Until they are fixed, those tests cannot reach the code that they check.

## 5. Findings without a test

Found by reading. No test, because the result is hard to observe from Dart, or because the item is small. Line numbers are at `4ff1c5407`.

### Lifetime

- `copyToClipboard` and `cutToClipboard`: the `getSelectedText` callback captures a raw `this`.
- External JS-handler replies capture a raw `targetWebView` and call `ResolveInternalHandlerWithReply` on it after Dart answers. These methods use no members, so make them static.
- `OnCreateWebView` default behaviour captures the raw `WebKitWebView*` of the opener (C4g tests this path and did not reproduce).
- `pasteFromClipboard` and `pasteAsPlainText` run a nested main loop in `gtk_clipboard_wait_for_text`. A dispose can run inside it. A clipboard owner that does not answer freezes the UI.
- WPEPlatform only: `SetOnFrameAvailable` passes a `WPEToplevel*` without a reference to `g_idle_add`.
- `gtk_window_` is a cached raw pointer. If the GTK window is finalized first (shutdown order), the destructor disconnects signals on a dead object.
- With legacy FDO, if the exportable or backend creation fails, `webview_` stays null. Not every public method checks for null.
- Check: the `create` signal returns the WebKit view of the popup, and the `InAppWebView` in the manager owns its only reference. If the manager is null, the `unique_ptr` dies at the end of the scope and WebKit gets a freed view.
- The texture fallback calls `CopyPixelBufferTo` on the raster thread through a raw `InAppWebView*`. The texture must be unregistered before the view is deleted.

### Leaks and requests that are never answered

- The destructor does not answer or release `pending_script_dialogs_`, `pending_permission_requests_` and `pending_auth_requests_`. The page promise never settles.
- Response-policy decisions for `onNavigationResponse` are referenced but not tracked. If Dart never answers, or the view is disposed, they leak.
- `pending_custom_scheme_requests_` is never used. A request that is not answered leaks its reference and the load hangs.
- `getCopyBackForwardList` never frees the two lists from WebKit.
- `ShowDatePicker` and `HideDatePicker` destroy the dialog without a response, so `DateDialogContext` leaks each time. `HideAllPopups` runs on every scroll, resize and load.
- A second `<select>` while one is open overwrites `webkit_option_menu_`: the old reference leaks and the old menu stays open. The `close` signal of `WebKitOptionMenu` is not connected. The destructor does not close the menu.

### Wrong behavior, small

- The context-menu item "Copy Image" copies the image URI. "Open in New Window" items load in the current view.
- The stock actions for spelling, font, outline and inspect end in `break` with a comment about a GAction fallback that never runs.
- The context menu is placed at the global pointer position, not at the hit position. Wayland does not give a global position.
- `SendKeyEvent` returns from the shortcut path before `current_modifiers_` is updated. Non-Latin layouts never match the shortcut table.
- Legacy `SetCursorPos` truncates `x*scale` instead of rounding: 1 px drift at fractional scales.
- `setSettings` compiles the content blockers again on every call, also when they did not change. `newSettingsMap` is not used.
- `OnDomFullscreenRequest` sets and clears `waiting_fullscreen_notify_` in the same call, so the guard never blocks.
- With a null SHM buffer, `OnExportShmBuffer` releases the buffer but does not send frame-complete, so rendering can stop.
- `egl_import_failed_permanently` is a static for the whole process. One failure turns off EGL import for every view.
- `ReadPixelsFromEglImage` needs a current GL context on the main thread, which is usually absent, so the readback is skipped. `glReadPixels` is also bottom-up.
- `web_process_crashed_` is never read or written. After a web-process crash, the platform path keeps the old buffer and image bound to the texture.
- `initializeWindowIdJS` sets the window id with a one-time evaluation, not a user script, so the next navigation of the popup loses it.
- Popup creation params never set `plugin`, so `plugin_` is null in popups.
- HTTP auth stores credentials with the libsecret protocol `http`, also for `https`. With PERMANENT persistence, the credentials are also stored in the WebKit store.
- Paste goes through `execCommand('insertText')`, so the `paste` handlers of the page never run, and rich content is lost. Copy runs `navigator.clipboard.writeText` or a temporary `<textarea>` in the page.
- Media pause, suspend and close act only on the top document. The suspend state is stored in a `data-was-playing` attribute that the page can see and change.
- The color, date and cursor handlers act on `this`, not on the target view.
- `addWebMessageListener` puts the scheme into JS without escaping. A second listener with the same name replaces the first without `dispose()`.
- `JSON.stringify` that throws (cycles, BigInt) leaves an exception on the JSC context.
- `ResolveInternalHandlerWithReply` creates a new `JSCContext` (a JS VM) for each reply and evaluates the JSON as code. A throw returns `undefined`, so the null fallback never runs.
- `wpe_fdo_initialize_for_egl_display` and `eglInitialize` run once per view.
- `GetDmaBufFd` always returns false.
- `loadData` and the other load methods log "called while loading" on every call, also when idle.
- `WebStorageManager::removeDataModifiedSince` passes the Unix timestamp in seconds as the `GTimeSpan` of `webkit_website_data_manager_clear`. WebKit reads it as "modified in the last N microseconds", with 0 meaning all data. Only timestamp 0 works; a recent date clears almost nothing. Found 2026-10-20 (Telosnex app_storage ADR 001, A2); not fixed.

### Comments that are wrong

- "Called from WPE's thread" on the FDO export callbacks and `ReadPixelsFromEglImage`. The FDO callbacks run on the main `GMainContext`.
- `SetupMonitorChangeHandlers` says `monitors-changed`. The code connects `monitor-added` and `monitor-removed`.
- Platform `SetCursorPos` says "Scale to physical pixels" but passes logical coordinates.

### Checked and correct

- The triple pixel buffer is safe: the reader holds `buffer_swap_mutex_` for the whole copy.
- The stride handling in `ConvertARGB32ToRGBA` and `GetPixelBufferSize` is correct (`data.size()` over-allocates only).
- `saveState` and `restoreState`, the context-menu references, the hit-test references, the proposed-credential frees and `saveWebArchive` are balanced.
- `select_files` with `file://` URIs is correct.

## 6. Open questions

1. **Backend. Answered 2026-10-19: legacy is not intended. The check fails.** `linux/CMakeLists.txt` prefers WPEPlatform and falls back to legacy FDO only if `webkit_web_view_get_wpe_view` does not link. The check sets `CMAKE_REQUIRED_LIBRARIES` to `${WPE_WEBKIT_LIBRARIES}`, which are bare names (`WPEWebKit-2.0`, `wpe-1.0`) without the library directories. A system WPE in `/usr/lib` links. The bundled SDK in `~/.cache/flutter_inappwebview/wpe-sdk/` does not: `ld: cannot find -lWPEWebKit-2.0`. The SDK has the function (header line 375, exported from `libWPEWebKit-2.0.so`), and the same test links with `pkg-config --libs`. So every SDK build, including the Snap and Flatpak, builds legacy FDO. Fix: use `${WPE_WEBKIT_LINK_LIBRARIES}` and `${WPE_PLATFORM_LINK_LIBRARIES}` (full paths). That fix switches shipped builds to WPEPlatform, which no test has run on yet. Owner decision. **Fixed 2026-10-19, see section 7.**
2. **Decided 2026-10-19.** Fixes go to our fork only. W18 is patched in the fork's copy of `flutter_inappwebview_platform_interface`. The first pass is C1, then W16 to W19.

## 7. Fix status (2026-10-19)

Commits `84367c1d8` and the WPEBuffer fix after it, on `review/inappwebview-lifetime`.

**Backend.** The CMake check now links with full library paths. Builds with the bundled SDK use WPEPlatform (`WEBKIT_HAS_WPE_PLATFORM_API=1`, no FDO symbols in the plugin). The fixes for C1 also apply to the legacy FDO path, which stays the fallback.

**Fixed, test passes (normal and ASan):**

| ID | Fix |
| --- | --- |
| C1, C1b, C1c | FDO callbacks get a `WpeBackendLink`. The destructor clears it. Pending JS calls use a `GCancellable` that the destructor cancels. |
| C4d, C4e | Permission and auth callbacks hold a `weak_ptr` to the view. The destructor denies or cancels pending requests. |
| C10 | The TLS callback copies `failing_uri` and loads it after PROCEED. |
| C13 (new) | WPEPlatform only. The view kept the last `WPEBuffer` without a reference. WebKit freed it on reload, and the next frame read it. Found by ASan in C5 and C10 on WPEPlatform. The view now holds a reference. |
| W16 | `previousFailureCount` is an int. Linux values for `HttpAuthResponseAction`. |
| W17 | `SslError.code` is an int. Linux values for `SslErrorType`. |
| W18 | Linux values for `PermissionResourceType` (platform interface in this fork). `DEVICE_INFO` maps to `UNKNOWN`. |
| W19 | The popup view is stored in the plugin's `InAppWebViewManager`, also for headless parents. `createInAppWebView` and headless `run` take it by `windowId`. |

**Unblocked, now pass:** C4f, C5, S3.

**Unblocked, now red:** S4a (origin has path and query), S4b (iframe origin), C5b (popups that opened while the opener lived are not freed when it closes: 3 of 3).

**Unchanged on WPEPlatform:** the other results in sections 1 to 3. The ASan crashes C4a, C4b, C4c, C6, C8a, C8b, C8c and C9b reproduce on WPEPlatform as on FDO.

### 7.1 Second pass (2026-10-20)

Commits `ede666708` (crashes), `e0055ec8a` (security), `b9904f82c` (behavior) and the W23 test fix. Full suite, normal and ASan builds: 96 pass. The only reds are S4b and W6b.

**Fixed:** C2, C2b, C3, C4a-c, C5b, C6, C7, C8a-d, C9b; S1, S1b, S1c, S2, S4a, S5, S8a-d; W1, W1b, W2a, W3a-d, W4, W5a-c, W6a, W6c, W7, W8, W10-W13, W22-W24.

**Notes on the fixes:**
- C7 and W13 had a second cause: a page fetch() to a custom scheme always failed. Responses now carry CORS headers, and the scheme is CORS-enabled and secure.
- W23 had a second cause: native named the listener channel with its own id, so no listener message reached Dart, for any origin.
- S2 and S5 changed how tests open dialogs. Page JS cannot call internal handlers, so C8a, C8b and W4 open the dialogs with a real tap. New tests: S2-control, S2b, S5b.
- W12: with `javaScriptCanOpenWindowsAutomatically` off, every `window.open` is blocked, also with a user gesture. WebKit counts `evaluateJavascript` as a gesture, so a gesture rule could not be tested.
- W5a uses the same XHR path as `postUrl`. The response replaces the document; the URL stays the old one. WebKit has no API for a request body.

**Not fixed:**

| ID | Why |
| --- | --- |
| S4b | WebKit does not send a permission request from a cross-origin iframe for `Notification`, and its permission API has no frame origin. The test cannot be reached, and there is no API to fix it with. |
| W6b | The WebKit navigation API has no frame information. `get_frame_name` is the link target, not the frame. |

**New findings:**

| ID | Finding |
| --- | --- |
| N1 | `allowedOriginRules` of user scripts and plugin scripts, `pluginScriptsOriginAllowList` and `javaScriptBridgeOriginAllowList` are never enforced. `createWebKitUserScript` passes no allow list to WebKit. The bridge is injected on every origin. `javaScriptHandlersOriginAllowList` (S1) still applies. |
| N2 | A web message listener added while the first page still loads can miss the next document. W23 now waits for the first page; the race is not fixed. |

### 7.2 N1 and N2 (2026-10-20)

Commit `2b36bdb79`. Full suite, normal and ASan builds: the only reds are S4b and W6b. New tests N1a-control, N1a-d and N2 are red on `8657a3980`.

- **N1, fixed.** A script runs only where `window.location.origin` is one of its rules. A rule is an exact origin, as for `javaScriptHandlersOriginAllowList` (S1). `'*'` or null allows every origin, and an empty list allows none. An empty bridge list turns the bridge off. WebKit's allow list ignores ports, so the check is in JS, as on iOS, macOS and Windows. Those platforms use regular expressions; Android allows `*.` subdomain rules. Linux does neither.
- **N1 rule format, owner decision (2026-10-20): Android rules.** All four Linux allow lists (handlers, bridge, plugin scripts, user scripts) accept `'*'`, exact origins, and `scheme://*.domain[:port]` subdomain rules (any depth, not the domain itself). Regular expressions are not supported: Darwin's unanchored `RegExp.test` has the S1 hole. The handler list now blocks every origin when empty, as documented. Docs have a NOTE for Linux. Tests S1d, S1e, N1e.
- **N2, fixed. The cause was not the listener.** If a load starts before the previous load finishes, WebKit finishes the old load after the view URI is already the new URL. `onLoadStop` then reported the new URL for the old document. W23 waited for that event and ran JS in the old document. A `load-finished` while another load runs is now skipped. W23 again adds its listener during the first load.

## Black WebView on GPU hardware (2026-10-21)

Found while testing C11 on a Raspberry Pi CM5 (V3D, labwc, WPEPlatform):
every visible WebView drew black. The plugin imported each DMA-BUF frame as
an EGL image on WPE's offscreen display (`wpe_buffer_import_to_egl_image`),
then bound it in Flutter's GTK GL context, which uses GDK's EGL display.
An EGL image works only on the display that made it: every
`glEGLImageTargetTexture2DOES` failed with `GL_INVALID_VALUE`. The VM never
showed it because it only gets SHM buffers.

Fix: `wpe_frame_egl_image.cc`. Frames carry the DMA-BUF `WPEBuffer`; the
texture and the in-app browser make the EGL image on their current display
from the buffer's planes (`EGL_LINUX_DMA_BUF_EXT`, with modifiers when
supported), cached per buffer and display and destroyed when WebKit frees
the buffer. No pixel copies. If there is no EGL display (GDK on X11 uses
GLX) or an import fails, zero-copy turns off for the process and DMA-BUF
frames go through `wpe_buffer_import_to_pixels`.

Pi result: the page animates on screen (8 of 8 captures differ); 8,400
binds in 2.5 minutes, 0 GL errors; memory and file descriptors flat
(RSS 219.7 to 220.1 MB, 62 to 63 fds); fallback never triggered.
Not tested: the X11/GLX fallback, and GPUs other than V3D.

