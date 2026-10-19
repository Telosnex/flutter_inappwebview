// Findings from the in_app_webview.cc review (pin 4ff1c5407). Each test runs
// a real WPE WebKit view through the plugin. Status on the pin, Ubuntu
// 26.04 arm64, legacy FDO backend, real Plasma session (2026-10-18):
//
//   KI-1 CRASH  late frame after dispose -> OnExportShmBuffer on a freed
//               InAppWebView (the Telosnex abort).
//   X-1  CRASH  page JS -> std::terminate (json type_error, uncaught).
//   X-2  FAIL   page JS spoofs internal bridge events.
//   X-3  FAIL   origin allow list is a substring match.
//   X-4  FAIL   custom scheme dead after the registering view is disposed.
//   X-5  CRASH  any download with useOnDownloadStart: WebKit finishes it,
//               then the plugin cancels a finished download.
//
// Run ONE test per process: a native crash ends the whole run, and
// `flutter test --plain-name` is the only filter (a bundle built with -t
// ignores it). For a native backtrace, see the Telosnex LINUX_WORKLOG
// (trace-crash2.py; gdb cannot read registers on the arm64 VM).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_linux/flutter_inappwebview_linux.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// A page that repaints every frame, so frames keep arriving.
const _animatedPage = '''<!doctype html><html><body style="margin:0">
<canvas id="c" width="300" height="200"></canvas><script>
const g = document.getElementById('c').getContext('2d');
let n = 0;
(function draw() {
  g.fillStyle = 'hsl(' + (n++ % 360) + ',80%,50%)';
  g.fillRect(0, 0, 300, 200);
  requestAnimationFrame(draw);
})();
</script></body></html>''';

Future<void> _settle(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

Future<LinuxHeadlessInAppWebView> _start(
  WidgetTester tester, {
  String html = _animatedPage,
  InAppWebViewSettings? settings,
  void Function(LinuxInAppWebViewController)? onCreated,
  Completer<void>? loaded,
  void Function(ConsoleMessage)? onConsole,
  FutureOr<CustomSchemeResponse?> Function(dynamic, WebResourceRequest)?
  onScheme,
  FutureOr<DownloadStartResponse?> Function(dynamic, DownloadStartRequest)?
  onDownload,
}) async {
  final view = LinuxHeadlessInAppWebView(
    LinuxHeadlessInAppWebViewCreationParams(
      initialData: InAppWebViewInitialData(
        data: html,
        baseUrl: WebUri('https://example.com/'),
      ),
      initialSettings: settings,
      initialSize: const Size(300, 200),
      onWebViewCreated: (c) =>
          onCreated?.call(c as LinuxInAppWebViewController),
      onLoadStop: (_, _) {
        if (loaded != null && !loaded.isCompleted) loaded.complete();
      },
      onConsoleMessage: onConsole == null ? null : (_, m) => onConsole(m),
      onLoadResourceWithCustomScheme: onScheme,
      onDownloadStarting: onDownload,
    ),
  );
  await view.run();
  return view;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(LinuxInAppWebViewPlatform.registerWith);

  // KI-1. The WebKitWebView outlives ~InAppWebView while a JS call is
  // pending (its GTask holds a ref). The FDO exportable keeps a raw
  // InAppWebView* as client data; the next frame calls OnExportShmBuffer on
  // freed memory. Expected today: process abort (glibc mutex error) or ASan
  // heap-use-after-free in OnExportShmBuffer. Expected after the fix: pass.
  testWidgets('KI-1 frames after dispose with a pending JS call do not crash', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    for (var round = 0; round < 5; round++) {
      final loaded = Completer<void>();
      late LinuxInAppWebViewController controller;
      final view = await _start(
        tester,
        loaded: loaded,
        onCreated: (c) => controller = c,
      );
      await loaded.future.timeout(const Duration(seconds: 20));
      // Never settles: keeps a WebKit ref after dispose.
      unawaited(
        controller
            .callAsyncJavaScript(functionBody: 'await new Promise(() => {});')
            .then((_) {}, onError: (_) {}),
      );
      unawaited(
        controller
            .evaluateJavascript(source: 'new Promise(() => {})')
            .then((_) {}, onError: (_) {}),
      );
      await _settle(tester, const Duration(milliseconds: 200));
      await view.dispose();
      // Frames from the still-animating web process arrive here.
      await _settle(tester, const Duration(seconds: 3));
    }
    expect(true, isTrue, reason: 'reached the end without a native crash');
  });

  // X-1. Page JS reaches internal bridge handlers with no secret (the bridge
  // closure adds it). onWebMessagePortMessageReceived with a binary message
  // whose data holds a non-number throws json::type_error; only parse_error
  // is caught, so the exception leaves a GSignal callback -> std::terminate.
  testWidgets('X-1 page JS cannot abort the app via a malformed port message', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final loaded = Completer<void>();
    late LinuxInAppWebViewController controller;
    final view = await _start(
      tester,
      html: '<html><body>x</body></html>',
      loaded: loaded,
      onCreated: (c) => controller = c,
    );
    try {
      await loaded.future.timeout(const Duration(seconds: 20));
      await controller.evaluateJavascript(
        source: '''
window.flutter_inappwebview.callHandler('onWebMessagePortMessageReceived',
  {webMessageChannelId: 'x', index: 0,
   message: {type: 1, data: ['not-a-byte']}});
true;''',
      );
      await _settle(tester, const Duration(seconds: 2));
      // Still alive and responsive.
      expect(await controller.evaluateJavascript(source: '1 + 1'), 2);
    } finally {
      await view.dispose();
    }
  });

  // X-2. Page JS spoofs internal events: a console message that the page
  // never logged reaches onConsoleMessage through callHandler.
  testWidgets('X-2 page JS cannot spoof internal bridge events', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final loaded = Completer<void>();
    final messages = <String>[];
    late LinuxInAppWebViewController controller;
    final view = await _start(
      tester,
      html: '<html><body>x</body></html>',
      loaded: loaded,
      onCreated: (c) => controller = c,
      onConsole: (m) => messages.add(m.message),
    );
    try {
      await loaded.future.timeout(const Duration(seconds: 20));
      await controller.evaluateJavascript(
        source: '''
window.flutter_inappwebview.callHandler('onConsoleMessage',
  {level: 'error', message: 'spoofed-by-page'});
true;''',
      );
      await _settle(tester, const Duration(seconds: 2));
      expect(messages, isNot(contains('spoofed-by-page')));
    } finally {
      await view.dispose();
    }
  });

  // X-3. javaScriptHandlersOriginAllowList uses substring matching on the
  // top-level URL's "scheme://host[:port]".
  testWidgets('X-3 origin allow list matches the host exactly', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final calls = <String>[];
    for (final base in [
      'https://example.com.evil.test/',
      'https://notexample.com/',
    ]) {
      final loaded = Completer<void>();
      late LinuxInAppWebViewController controller;
      final view = LinuxHeadlessInAppWebView(
        LinuxHeadlessInAppWebViewCreationParams(
          initialData: InAppWebViewInitialData(
            data: '<html><body>x</body></html>',
            baseUrl: WebUri(base),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptHandlersOriginAllowList: {'https://example.com'},
          ),
          onWebViewCreated: (c) {
            controller = c as LinuxInAppWebViewController;
            controller.addJavaScriptHandler(
              handlerName: 'probe',
              callback: (_) {
                calls.add(base);
                return null;
              },
            );
          },
          onLoadStop: (_, _) {
            if (!loaded.isCompleted) loaded.complete();
          },
        ),
      );
      await view.run();
      try {
        await loaded.future.timeout(const Duration(seconds: 20));
        await controller.evaluateJavascript(
          source: "window.flutter_inappwebview.callHandler('probe'); true;",
        );
        await _settle(tester, const Duration(seconds: 1));
      } finally {
        await view.dispose();
      }
    }
    expect(calls, isEmpty, reason: 'handler ran for a non-allowed origin');
  });

  // X-4. Custom scheme handler is registered on the SHARED WebKitWebContext
  // with the registering view's raw `this`; disposing that view leaves a
  // dangling handler. The next request from another view uses freed memory
  // (crash), or is routed to the wrong view's Dart side.
  testWidgets(
    'X-4 custom scheme still works after the first view is disposed',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final settings = InAppWebViewSettings(resourceCustomSchemes: ['tnxtest']);
      Future<CustomSchemeResponse> respond(String who) async =>
          CustomSchemeResponse(
            contentType: 'text/plain',
            data: Uint8List.fromList(utf8.encode(who)),
          );

      final firstLoaded = Completer<void>();
      final first = await _start(
        tester,
        html: '<html><body>first</body></html>',
        settings: settings,
        loaded: firstLoaded,
        onScheme: (_, _) => respond('first'),
      );
      await firstLoaded.future.timeout(const Duration(seconds: 20));
      await first.dispose();
      await _settle(tester, const Duration(milliseconds: 500));

      final secondLoaded = Completer<void>();
      late LinuxInAppWebViewController controller;
      final second = await _start(
        tester,
        html: '<html><body>second</body></html>',
        settings: settings,
        loaded: secondLoaded,
        onCreated: (c) => controller = c,
        onScheme: (_, _) => respond('second'),
      );
      try {
        await secondLoaded.future.timeout(const Duration(seconds: 20));
        final result = await controller.callAsyncJavaScript(
          functionBody: "return await (await fetch('tnxtest://x/')).text();",
        );
        expect(result?.value, 'second');
      } finally {
        await second.dispose();
      }
    },
  );

  // X-5. With useOnDownloadStart, the plugin asks Dart and then cancels.
  // WebKit does not wait: no decide-destination handler, so it saves the
  // file to ~/Downloads within milliseconds, and the later cancel on the
  // finished download crashes inside WebKit. One view is enough.
  testWidgets('X-5 a download with onDownloadStarting does not crash', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    var asked = 0;
    final loaded = Completer<void>();
    late LinuxInAppWebViewController controller;
    final view = await _start(
      tester,
      html: '<html><body>a</body></html>',
      settings: InAppWebViewSettings(useOnDownloadStart: true),
      loaded: loaded,
      onCreated: (c) => controller = c,
      onDownload: (_, _) async {
        asked++;
        return DownloadStartResponse(
          handled: true,
          action: DownloadStartResponseAction.CANCEL,
        );
      },
    );
    try {
      await loaded.future.timeout(const Duration(seconds: 20));
      // A unique name, so the test never touches a real file of the user's.
      final name = 'tnx-review-${DateTime.now().microsecondsSinceEpoch}.bin';
      await controller.evaluateJavascript(
        source:
            "const l = document.createElement('a');"
            "l.href = URL.createObjectURL(new Blob(['x'], "
            "{type: 'application/octet-stream'}));"
            "l.download = '$name'; document.body.appendChild(l); "
            'l.click(); true;',
      );
      await _settle(tester, const Duration(seconds: 3));
      expect(asked, 1);
    } finally {
      await view.dispose();
    }
  });
}
