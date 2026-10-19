// Red tests for the crash risks in REVIEW_in_app_webview.md, section 1.
//
// Every test asserts the correct behavior: the app keeps running and the
// view answers. On the reviewed pin each one crashes, fails, or (for the
// use-after-free cases) shows an ASan heap-use-after-free. Run ONE test per
// process: `flutter test integration_test/review_crash_test.dart -d linux
// --plain-name "C4a "`. See the review, "Running the red tests".

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_linux/flutter_inappwebview_linux.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'review_common.dart';

/// Proves the process is still healthy after the scenario: a fresh view
/// loads and runs JS.
Future<void> expectStillWorks(WidgetTester tester) async {
  final probe = await TestView.start(tester);
  try {
    expect(await probe.js('6 * 7'), 42);
  } finally {
    await probe.dispose();
  }
  await settle(tester, const Duration(milliseconds: 500));
}

/// Holds a Dart callback open until the test releases it.
class Gate<T> {
  final _started = Completer<void>();
  final _release = Completer<T>();
  bool get started => _started.isCompleted;
  Future<T> hold() {
    if (!_started.isCompleted) _started.complete();
    return _release.future;
  }

  void release(T value) {
    if (!_release.isCompleted) _release.complete(value);
  }
}

/// Shows [body] in a visible 600x400 view and taps it at [dx] from the
/// center, so WebKit gets a trusted click.
Future<void> pumpVisibleAndTap(
  WidgetTester tester,
  String body, {
  double dx = 0,
}) async {
  final loaded = Completer<void>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          height: 400,
          child: Builder(
            builder: (context) => LinuxInAppWebViewWidget(
              LinuxInAppWebViewWidgetCreationParams(
                initialData: InAppWebViewInitialData(
                  data: '<!doctype html><body style="margin:0">$body</body>',
                  baseUrl: WebUri('https://example.com/'),
                ),
                onLoadStop: (_, _) {
                  if (!loaded.isCompleted) loaded.complete();
                },
              ),
            ).build(context),
          ),
        ),
      ),
    ),
  );
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!loaded.isCompleted && DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  await settle(tester, const Duration(milliseconds: 500));
  await tester.tapAt(
    tester.getCenter(find.byType(SizedBox).last) + Offset(dx, 0),
  );
  await settle(tester, const Duration(seconds: 1));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(LinuxInAppWebViewPlatform.registerWith);

  // C1 (KI-1). The FDO exportable keeps a raw InAppWebView* and outlives the
  // view while WebKit holds a ref (pending JS call). The next frame runs
  // OnExportShmBuffer on freed memory. ASan: heap-use-after-free in
  // OnExportShmBuffer, freed by ~HeadlessInAppWebView.
  testWidgets('C1 frames after dispose with a pending JS call', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    for (var round = 0; round < 5; round++) {
      final t = await TestView.start(tester, html: animatedPage);
      unawaited(
        t.controller
            .callAsyncJavaScript(functionBody: 'await new Promise(() => {});')
            .then((_) {}, onError: (_) {}),
      );
      await settle(tester, const Duration(milliseconds: 200));
      await t.dispose();
      await settle(tester, const Duration(seconds: 2));
    }
    await expectStillWorks(tester);
  });

  // C1b. Same raw pointer for the fullscreen handler: a fullscreen request
  // reaching the backend after dispose. requestFullscreen() needs a user
  // gesture, so the page asks from inside a click it synthesizes; WebKit
  // may refuse, in which case this checks only that dispose stays safe.
  testWidgets('C1b fullscreen request racing dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    for (var round = 0; round < 5; round++) {
      final t = await TestView.start(tester, html: animatedPage);
      unawaited(
        t
            .js('''document.body.addEventListener('click', () => {
  document.documentElement.requestFullscreen().catch(() => {});
}); document.body.click(); true;''')
            .then((_) {}, onError: (_) {}),
      );
      unawaited(
        t.controller
            .callAsyncJavaScript(functionBody: 'await new Promise(() => {});')
            .then((_) {}, onError: (_) {}),
      );
      await t.dispose();
      await settle(tester, const Duration(seconds: 1));
    }
    await expectStillWorks(tester);
  });

  // C2. Internal handler with a non-number byte: json type_error escapes a
  // GSignal callback -> std::terminate.
  testWidgets('C2 malformed port message from page JS', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      await t.js(
        '''window.flutter_inappwebview.callHandler('onWebMessagePortMessageReceived',
  {webMessageChannelId: 'x', index: 0, message: {type: 1, data: ['not-a-byte']}}); true;''',
      );
      await settle(tester, const Duration(seconds: 2));
      expect(await t.js('1 + 1'), 2);
    } finally {
      await t.dispose();
    }
  });

  // C2b. Same for the web message listener path.
  testWidgets('C2b malformed listener message from page JS', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      await t.js(
        '''window.flutter_inappwebview.callHandler('onWebMessageListenerPostMessageReceived',
  {jsObjectName: 'x', sourceOrigin: 'https://example.com', isMainFrame: true,
   message: {type: 1, data: [{}]}}); true;''',
      );
      await settle(tester, const Duration(seconds: 2));
      expect(await t.js('1 + 1'), 2);
    } finally {
      await t.dispose();
    }
  });

  // C3. With useOnDownloadStart, WebKit finishes the download before Dart
  // answers; the plugin then cancels a finished download -> SIGSEGV in
  // WebKit. Correct: Dart decides before the file is written, no crash.
  testWidgets('C3 download with onDownloadStarting', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final name = 'tnx-review-${DateTime.now().microsecondsSinceEpoch}.bin';
    final saved = File('${Platform.environment['HOME']}/Downloads/$name');
    var asked = 0;
    final t = await TestView.start(
      tester,
      settings: InAppWebViewSettings(useOnDownloadStart: true),
      onDownloadStarting: (_, _) async {
        asked++;
        return DownloadStartResponse(
          handled: true,
          action: DownloadStartResponseAction.CANCEL,
        );
      },
    );
    try {
      await t.js(
        "const l = document.createElement('a');"
        "l.href = URL.createObjectURL(new Blob(['x'], {type: 'application/octet-stream'}));"
        "l.download = '$name'; document.body.appendChild(l); l.click(); true;",
      );
      await settle(tester, const Duration(seconds: 3));
      expect(asked, 1);
      expect(
        saved.existsSync(),
        isFalse,
        reason: 'cancelled download was saved anyway',
      );
      expect(await t.js('1 + 1'), 2);
    } finally {
      if (saved.existsSync()) saved.deleteSync();
      await t.dispose();
    }
  });

  // C4a. shouldOverrideUrlLoading answered after dispose: the callback uses
  // `self` (pending_policy_decisions_ map).
  testWidgets('C4a navigation policy answered after dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final gate = Gate<NavigationActionPolicy?>();
    final t = await TestView.start(
      tester,
      settings: InAppWebViewSettings(useShouldOverrideUrlLoading: true),
      shouldOverrideUrlLoading: (_, a) async {
        if (a.request.url.toString().contains('next')) return gate.hold();
        return NavigationActionPolicy.ALLOW;
      },
    );
    unawaited(
      t
          .js("location.href = 'https://example.com/next'; true;")
          .then((_) {}, onError: (_) {}),
    );
    await waitFor(tester, () => gate.started, reason: 'policy request');
    await t.dispose();
    gate.release(NavigationActionPolicy.ALLOW);
    await settle(tester, const Duration(seconds: 1));
    await expectStillWorks(tester);
  });

  // C4b. onNavigationResponse answered after dispose. The callback reads
  // self->settings_ only when WebKit cannot display the MIME type, so the
  // server answers with one it cannot show.
  testWidgets('C4b response policy answered after dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    server.handlers['/next'] = (r, _) {
      r.response
        ..headers.set('content-type', 'application/x-review-unknown')
        ..write('x');
    };
    final gate = Gate<NavigationResponseAction?>();
    final t = await TestView.start(
      tester,
      settings: InAppWebViewSettings(useOnNavigationResponse: true),
      onNavigationResponse: (_, r) async {
        if ((r.response?.url.toString() ?? '').contains('next')) {
          return gate.hold();
        }
        return NavigationResponseAction.ALLOW;
      },
    );
    try {
      unawaited(
        t
            .js("location.href = '${server.url('/next')}'; true;")
            .then((_) {}, onError: (_) {}),
      );
      await waitFor(tester, () => gate.started, reason: 'response policy');
      await t.dispose();
      gate.release(NavigationResponseAction.ALLOW);
      await settle(tester, const Duration(seconds: 1));
      await expectStillWorks(tester);
    } finally {
      await server.close();
    }
  });

  // C4c. JS confirm answered after dispose: callback looks up
  // &self->pending_script_dialogs_.
  testWidgets('C4c confirm answered after dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final gate = Gate<JsConfirmResponse?>();
    final t = await TestView.start(tester, onJsConfirm: (_, _) => gate.hold());
    unawaited(
      t
          .js("setTimeout(() => confirm('q'), 0); true;")
          .then((_) {}, onError: (_) {}),
    );
    await waitFor(tester, () => gate.started, reason: 'confirm');
    await t.dispose();
    gate.release(
      JsConfirmResponse(
        handledByClient: true,
        action: JsConfirmResponseAction.CONFIRM,
      ),
    );
    await settle(tester, const Duration(seconds: 1));
    await expectStillWorks(tester);
  });

  // C4d. Permission request answered after dispose
  // (&self->pending_permission_requests_). Needs W18 fixed: until then the
  // event never reaches Dart and this fails waiting for it.
  testWidgets('C4d permission answered after dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    final gate = Gate<PermissionResponse?>();
    final t = await TestView.start(
      tester,
      url: server.url('/page'),
      onPermissionRequest: (_, _) => gate.hold(),
    );
    try {
      unawaited(
        t
            .js('Notification.requestPermission(); true;')
            .then((_) {}, onError: (_) {}),
      );
      await waitFor(tester, () => gate.started, reason: 'permission request');
      await t.dispose();
      gate.release(
        PermissionResponse(
          action: PermissionResponseAction.GRANT,
          resources: [],
        ),
      );
      await settle(tester, const Duration(seconds: 1));
      await expectStillWorks(tester);
    } finally {
      await server.close();
    }
  });

  // C4e. HTTP auth answered after dispose (&self->pending_auth_requests_).
  // Needs W16 fixed: until then the event never reaches Dart.
  testWidgets('C4e HTTP auth answered after dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    server.handlers['/auth'] = (r, _) {
      r.response
        ..statusCode = 401
        ..headers.set('WWW-Authenticate', 'Basic realm="review"');
    };
    final gate = Gate<HttpAuthResponse?>();
    final t = await TestView.start(
      tester,
      onReceivedHttpAuthRequest: (_, _) => gate.hold(),
    );
    try {
      unawaited(
        t
            .js("location.href = '${server.url('/auth')}'; true;")
            .then((_) {}, onError: (_) {}),
      );
      await waitFor(tester, () => gate.started, reason: 'auth request');
      await t.dispose();
      gate.release(HttpAuthResponse(action: HttpAuthResponseAction.CANCEL));
      await settle(tester, const Duration(seconds: 1));
      await expectStillWorks(tester);
    } finally {
      await server.close();
    }
  });

  // C4f. TLS error answered after dispose: callback uses `self`, and reads
  // `failing_uri`, which was only valid during the signal. Needs W17 fixed:
  // until then the event never reaches Dart.
  testWidgets('C4f TLS decision answered after dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start(https: true);
    final gate = Gate<ServerTrustAuthResponse?>();
    final t = await TestView.start(
      tester,
      onReceivedServerTrustAuthRequest: (_, _) => gate.hold(),
    );
    try {
      unawaited(
        t
            .js("location.href = '${server.url('/tls')}'; true;")
            .then((_) {}, onError: (_) {}),
      );
      await waitFor(tester, () => gate.started, reason: 'TLS decision');
      await t.dispose();
      gate.release(
        ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED),
      );
      await settle(tester, const Duration(seconds: 1));
      await expectStillWorks(tester);
    } finally {
      await server.close();
    }
  });

  // C4g. onCreateWindow answered after the parent is disposed: the default
  // behaviour loads the URL into the parent's WebKitWebView pointer.
  testWidgets('C4g create-window answered after parent dispose', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final gate = Gate<bool?>();
    final t = await TestView.start(
      tester,
      settings: InAppWebViewSettings(
        javaScriptCanOpenWindowsAutomatically: true,
        supportMultipleWindows: true,
      ),
      onCreateWindow: (_, _) => gate.hold(),
    );
    unawaited(
      t
          .js("window.open('https://example.com/popup'); true;")
          .then((_) {}, onError: (_) {}),
    );
    await waitFor(tester, () => gate.started, reason: 'create window');
    await t.dispose();
    gate.release(false);
    await settle(tester, const Duration(seconds: 1));
    await expectStillWorks(tester);
  });

  // C4h. createWebMessageChannel: the JS-completion callback captures raw
  // `self` and writes web_message_channels_ after the JS settles.
  testWidgets('C4h createWebMessageChannel racing dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    for (var round = 0; round < 10; round++) {
      final t = await TestView.start(tester);
      unawaited(
        t.controller.createWebMessageChannel().then((_) {}, onError: (_) {}),
      );
      await t.dispose();
      await settle(tester, const Duration(milliseconds: 300));
    }
    await expectStillWorks(tester);
  });

  // C5. A popup shares the parent's WebKitUserContentManager. Disposing the
  // popup strips the parent's scripts and "callHandler" registration and
  // leaves its own signal handler with a dangling `this`.
  //
  // Needs working popups (W19). Until then the popup never gets a bridge,
  // and this test fails at its precondition, saying so.
  testWidgets('C5 parent bridge still works after its popup is disposed', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final calls = <String>[];
    LinuxHeadlessInAppWebView? popup;
    LinuxInAppWebViewController? popupController;
    final parent = await TestView.start(
      tester,
      settings: InAppWebViewSettings(
        javaScriptCanOpenWindowsAutomatically: true,
        supportMultipleWindows: true,
      ),
      onCreated: (c) => c.addJavaScriptHandler(
        handlerName: 'probe',
        callback: (args) {
          calls.add('${args.isEmpty ? '' : args.first}');
          return 'ok';
        },
      ),
      onCreateWindow: (_, action) async {
        popup = LinuxHeadlessInAppWebView(
          LinuxHeadlessInAppWebViewCreationParams(
            windowId: action.windowId,
            initialSize: const Size(200, 200),
            onWebViewCreated: (c) =>
                popupController = c as LinuxInAppWebViewController,
          ),
        );
        await popup!.run();
        return true;
      },
    );
    try {
      expect(
        await parent.asyncJs(
          "return await window.flutter_inappwebview.callHandler('probe', 'before');",
        ),
        'ok',
      );
      await parent.js("window.open('https://example.com/popup'); true;");
      await waitFor(
        tester,
        () => popupController != null,
        reason: 'popup created',
      );
      await settle(tester, const Duration(seconds: 2));
      // Precondition: the popup is the window WebKit opened (shares the
      // parent's content manager). Fails today: W19.
      expect(
        await popupController!.evaluateJavascript(
          source: 'typeof window.flutter_inappwebview',
        ),
        'object',
        reason: 'precondition: popup not attached to the opened window (W19)',
      );
      await popup!.dispose();
      await settle(tester, const Duration(milliseconds: 500));
      final after = await parent
          .asyncJs(
            "return await Promise.race([window.flutter_inappwebview.callHandler('probe', 'after'),"
            " new Promise(r => setTimeout(() => r('timeout'), 3000))]);",
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => 'dart-timeout',
          );
      expect(after, 'ok');
      expect(calls, ['before', 'after']);
    } finally {
      await parent.dispose();
    }
  });

  // C5b. When the client handles onCreateWindow, the parent stores the
  // popup's InAppWebView (related to the parent's WebKitWebView) in the
  // manager, and nothing ever removes it. Disposing the parent leaves it
  // there. Correct: the popup is released with (or before) its opener.
  testWidgets('C5b unclaimed popups are released with their opener', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    if (await skipWithoutHooks()) return;
    await warmUpWebKit(tester);
    final before = await Hooks.instanceCount('WebKitWebView');
    for (var round = 0; round < 3; round++) {
      var asked = false;
      final t = await TestView.start(
        tester,
        settings: InAppWebViewSettings(
          javaScriptCanOpenWindowsAutomatically: true,
          supportMultipleWindows: true,
        ),
        onCreateWindow: (_, _) async {
          asked = true;
          return true;
        },
      );
      await t.js("window.open('https://example.com/popup'); true;");
      await waitFor(tester, () => asked, reason: 'onCreateWindow');
      await t.dispose();
      await settle(tester, const Duration(seconds: 1));
    }
    await settle(tester, const Duration(seconds: 2));
    final after = await Hooks.instanceCount('WebKitWebView');
    debugPrint('REVIEW: WebKitWebView before=$before after=$after');
    // Precondition: the popup path actually ran (counter sees views).
    final probe = await TestView.start(tester);
    final withProbe = await Hooks.instanceCount('WebKitWebView');
    await probe.dispose();
    expect(
      withProbe,
      greaterThan(after),
      reason: 'instance counter not working',
    );
    expect(after, before);
    await expectStillWorks(tester);
  });

  // C6. Content-blocker compile still pending at dispose: the async
  // completion uses the freed handler, then loads initial content on the
  // freed view. Compiling must outlast the dispose round trip, so the rule
  // list is large and regex-heavy, and dispose starts right after run().
  testWidgets('C6 dispose while content blockers compile', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final blockers = [
      for (var i = 0; i < 5000; i++)
        ContentBlocker(
          trigger: ContentBlockerTrigger(
            urlFilter:
                '^https?://([a-z0-9-]+\\.)*blocked-$i\\.example(:[0-9]+)?/.*[?&]id=[0-9]+',
          ),
          action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
        ),
    ];
    var raced = 0;
    for (var round = 0; round < 5; round++) {
      final t = await TestView.start(
        tester,
        waitForLoad: false,
        settings: InAppWebViewSettings(contentBlockers: blockers),
      );
      // Initial content loads only after the compile finishes; no load yet
      // means dispose races the compile.
      if (t.loadStops.isEmpty) raced++;
      await t.dispose();
      await settle(tester, const Duration(seconds: 2));
    }
    debugPrint('REVIEW: C6 disposed before first load in $raced of 5 rounds');
    expect(
      raced,
      greaterThan(0),
      reason: 'precondition: compile never pending at dispose',
    );
    await expectStillWorks(tester);
  });

  // C7. Custom scheme handler registered on the shared context with raw
  // `this`: after the registering view is disposed, another view's request
  // must still reach its own handler.
  testWidgets('C7 custom scheme after the registering view is disposed', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final settings = InAppWebViewSettings(resourceCustomSchemes: ['tnxtest']);
    CustomSchemeResponse reply(String who) => CustomSchemeResponse(
      contentType: 'text/plain',
      data: Uint8List.fromList(who.codeUnits),
    );
    final first = await TestView.start(
      tester,
      settings: settings,
      onLoadResourceWithCustomScheme: (_, _) => reply('first'),
    );
    await first.dispose();
    await settle(tester, const Duration(milliseconds: 500));
    final second = await TestView.start(
      tester,
      settings: settings,
      onLoadResourceWithCustomScheme: (_, _) => reply('second'),
    );
    try {
      final text = await second
          .asyncJs("return await (await fetch('tnxtest://x/')).text();")
          .timeout(const Duration(seconds: 10), onTimeout: () => 'timeout');
      expect(text, 'second');
    } finally {
      await second.dispose();
    }
  });

  // C8a. Color dialog answered after dispose: "response" handler gets raw
  // `this`; the destructor never closes the dialog.
  testWidgets('C8a color dialog answered after dispose', (tester) async {
    if (await skipWithoutHooks()) return;
    // A real tap: page JS cannot open the dialog (S5).
    await pumpVisibleAndTap(
      tester,
      '<input type="color" style="width:100vw;height:100vh">',
    );
    expect(await Hooks.dialogs(), contains('color'));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await settle(tester, const Duration(milliseconds: 300));
    // Correct: dispose closed the dialog. Answering an open one would run
    // the handler on the freed view.
    final stillOpen = (await Hooks.dialogs()).contains('color');
    if (stillOpen) await Hooks.respond('color', color: '#00ff00');
    await settle(tester, const Duration(seconds: 1));
    await expectStillWorks(tester);
    expect(stillOpen, isFalse, reason: 'color dialog outlived its view');
  });

  // C8b. Date dialog: same, through the DateDialogContext's raw view.
  testWidgets('C8b date dialog answered after dispose', (tester) async {
    if (await skipWithoutHooks()) return;
    // The date script opens its dialog for a tap on the right 30 px.
    await pumpVisibleAndTap(
      tester,
      '<input type="date" value="2024-05-05" '
      'style="width:100vw;height:100vh;box-sizing:border-box">',
      dx: 290,
    );
    expect(await Hooks.dialogs(), isNotEmpty);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await settle(tester, const Duration(milliseconds: 300));
    final stillOpen = (await Hooks.dialogs()).isNotEmpty;
    if (stillOpen) await Hooks.respond('', ok: true);
    await settle(tester, const Duration(seconds: 1));
    await expectStillWorks(tester);
    expect(stillOpen, isFalse, reason: 'date dialog outlived its view');
  });

  // C8c. File chooser: the GTK dialog's context holds the raw view; the
  // destructor never closes it (and HideFileChooser refuses within 200 ms).
  testWidgets('C8c file dialog answered after dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    if (await skipWithoutHooks()) return;
    final t = await TestView.start(
      tester,
      html: '<!doctype html><input id="f" type="file">',
    );
    // A file input needs a user gesture; WebKit treats a click dispatched
    // while handling a script call from the UI process as user-initiated
    // only sometimes, so try a synthetic click and skip if nothing opened.
    await t.js("document.getElementById('f').click(); true;");
    await settle(tester, const Duration(seconds: 1));
    if (!(await Hooks.dialogs()).contains('file')) {
      await t.dispose();
      markTestSkipped('file chooser needs a real user gesture here');
      return;
    }
    await t.dispose();
    await settle(tester, const Duration(milliseconds: 300));
    final stillOpen = (await Hooks.dialogs()).contains('file');
    if (stillOpen) await Hooks.respond('file', ok: false);
    await settle(tester, const Duration(seconds: 1));
    await expectStillWorks(tester);
    expect(stillOpen, isFalse, reason: 'file dialog outlived its view');
  });

  // C9a. loadData spins the main loop inside the method call. A dispose
  // queued behind it runs in that spin; loadData then continues on the
  // freed view. Both calls are sent in the same frame, so the dispose
  // message is already queued when loadData starts spinning.
  testWidgets('C9a dispose queued behind loadData', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    for (var round = 0; round < 20; round++) {
      final t = await TestView.start(tester, html: animatedPage);
      // Keep WebKit busy so stop_loading has work and the spin has events.
      unawaited(t.controller.loadData(data: animatedPage).catchError((_) {}));
      final load = t.controller.loadData(data: '<p>$round</p>');
      final gone = t.dispose();
      await Future.wait([load.catchError((_) {}), gone]);
      await settle(tester, const Duration(milliseconds: 100));
    }
    await expectStillWorks(tester);
  });

  // C9b. postUrl schedules a 100 ms timeout with raw `this`.
  testWidgets('C9b dispose right after postUrl', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    try {
      for (var round = 0; round < 5; round++) {
        final t = await TestView.start(tester);
        await t.controller.postUrl(
          url: WebUri(server.url('/post')),
          postData: Uint8List.fromList('a=1'.codeUnits),
        );
        await t.dispose();
        await settle(tester, const Duration(milliseconds: 400));
      }
      await expectStillWorks(tester);
    } finally {
      await server.close();
    }
  });

  // C10. TLS PROCEED: the async callback reads `failing_uri`, a pointer that
  // was only valid during the signal, to reload the page. Correct: the page
  // the user agreed to is the one that loads. Needs W17 fixed first (today
  // the event never reaches Dart). ASan shows the stale read.
  testWidgets('C10 TLS proceed loads the URL that failed', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start(https: true);
    server.handlers['/tls-target'] = (r, _) {
      r.response
        ..headers.set('content-type', 'text/html')
        ..write('<title>target</title>');
    };
    var asked = 0;
    final t = await TestView.start(
      tester,
      onReceivedServerTrustAuthRequest: (_, _) async {
        asked++;
        // Let the signal's strings go out of scope first.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.PROCEED,
        );
      },
    );
    try {
      await t.controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(server.url('/tls-target'))),
      );
      await settle(tester, const Duration(seconds: 3));
      expect(
        asked,
        greaterThanOrEqualTo(1),
        reason: 'precondition: W17 (TLS event never reaches Dart)',
      );
      expect(await t.js('document.title'), 'target');
    } finally {
      await t.dispose();
      await server.close();
    }
  });

  // C12. setSize with zero or negative sizes is forwarded to WPE.
  testWidgets('C12 zero and negative sizes', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester, html: animatedPage);
    try {
      await t.view.setSize(const Size(0, 0));
      await settle(tester, const Duration(milliseconds: 500));
      await t.view.setSize(const Size(-5, -5));
      await settle(tester, const Duration(milliseconds: 500));
      await t.view.setSize(const Size(300, 200));
      await settle(tester, const Duration(milliseconds: 500));
      expect(await t.js('1 + 1'), 2);
    } finally {
      await t.dispose();
    }
  });

  // C1c. Pointer-lock handler: same raw `this` as the frame callbacks.
  // requestPointerLock() racing dispose. (Needs a user gesture in WebKit;
  // a synthetic click may not count, so this mostly checks dispose safety.)
  testWidgets('C1c pointer lock request racing dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    for (var round = 0; round < 5; round++) {
      final t = await TestView.start(tester, html: animatedPage);
      unawaited(
        t
            .js('''document.body.addEventListener('click', () => {
  document.body.requestPointerLock();
}); document.body.click(); true;''')
            .then((_) {}, onError: (_) {}),
      );
      unawaited(
        t.controller
            .callAsyncJavaScript(functionBody: 'await new Promise(() => {});')
            .then((_) {}, onError: (_) {}),
      );
      await t.dispose();
      await settle(tester, const Duration(seconds: 1));
    }
    await expectStillWorks(tester);
  });

  // C8d. <select> popup open at dispose: the option-menu popup and the
  // WebKitOptionMenu are not closed by the destructor; clicking an item
  // afterwards runs the callback on the freed view. Uses a visible view so
  // a real tap opens the popup.
  testWidgets('C8d select popup answered after dispose', (tester) async {
    if (await skipWithoutHooks()) return;
    final created = Completer<void>();
    Widget view() => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          height: 400,
          child: Builder(
            builder: (context) => LinuxInAppWebViewWidget(
              LinuxInAppWebViewWidgetCreationParams(
                initialData: InAppWebViewInitialData(
                  data:
                      '<!doctype html><body style="margin:0"><select id="s" '
                      'style="width:100vw;height:100vh;font-size:40px">'
                      '<option>a</option><option>b</option></select></body>',
                  baseUrl: WebUri('https://example.com/'),
                ),
                onLoadStop: (_, _) {
                  if (!created.isCompleted) created.complete();
                },
              ),
            ).build(context),
          ),
        ),
      ),
    );
    await tester.pumpWidget(view());
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (!created.isCompleted && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    debugPrint('REVIEW: C8d loaded=${created.isCompleted}');
    await settle(tester, const Duration(milliseconds: 500));
    await tester.tapAt(tester.getCenter(find.byType(SizedBox).last));
    debugPrint('REVIEW: C8d tapped');
    await settle(tester, const Duration(seconds: 1));
    debugPrint('REVIEW: C8d popup=${await Hooks.popupVisible()}');
    expect(
      await Hooks.popupVisible(),
      isTrue,
      reason: 'precondition: select popup did not open',
    );
    // Remove the widget: disposes the view while the popup is open.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    debugPrint('REVIEW: C8d widget removed');
    await settle(tester, const Duration(seconds: 1));
    final stillOpen = await Hooks.popupVisible();
    debugPrint('REVIEW: C8d stillOpen=$stillOpen');
    if (stillOpen) await Hooks.clickPopupItem(1, 'ii');
    await settle(tester, const Duration(seconds: 1));
    await expectStillWorks(tester);
    expect(stillOpen, isFalse, reason: 'select popup outlived its view');
  });

  // C8d-control. Same as C8d without opening the popup: if this also
  // dies, the problem is visible-view dispose, not the popup.
  // (C8d) <select> popup open at dispose: the option-menu popup and the
  // WebKitOptionMenu are not closed by the destructor; clicking an item
  // afterwards runs the callback on the freed view. Uses a visible view so
  // a real tap opens the popup.
  testWidgets('C8d-control visible view removed without a popup', (
    tester,
  ) async {
    if (await skipWithoutHooks()) return;
    final created = Completer<void>();
    Widget view() => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          height: 400,
          child: Builder(
            builder: (context) => LinuxInAppWebViewWidget(
              LinuxInAppWebViewWidgetCreationParams(
                initialData: InAppWebViewInitialData(
                  data:
                      '<!doctype html><body style="margin:0"><select id="s" '
                      'style="width:100vw;height:100vh;font-size:40px">'
                      '<option>a</option><option>b</option></select></body>',
                  baseUrl: WebUri('https://example.com/'),
                ),
                onLoadStop: (_, _) {
                  if (!created.isCompleted) created.complete();
                },
              ),
            ).build(context),
          ),
        ),
      ),
    );
    await tester.pumpWidget(view());
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (!created.isCompleted && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    debugPrint('REVIEW: C8d-control loaded=${created.isCompleted}');
    await settle(tester, const Duration(milliseconds: 500));
    // Remove the widget: disposes the view while the popup is open.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    debugPrint('REVIEW: C8d-control widget removed');
    await settle(tester, const Duration(seconds: 1));
    await expectStillWorks(tester);
  });
}
