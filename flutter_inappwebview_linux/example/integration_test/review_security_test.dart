// Red tests for the security findings in REVIEW_in_app_webview.md,
// section 2. Each asserts the secure behavior; on the reviewed pin each
// fails. Run one test per process (--plain-name "S1 ").

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_linux/flutter_inappwebview_linux.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'review_common.dart';

/// Loads [baseUrl] with an allow list of {'https://example.com'} and reports
/// whether page JS reached the 'probe' handler.
Future<bool> handlerReachableFrom(WidgetTester tester, String baseUrl) async {
  var called = false;
  final t = await TestView.start(
    tester,
    baseUrl: baseUrl,
    settings: InAppWebViewSettings(
      javaScriptHandlersOriginAllowList: {'https://example.com'},
    ),
    onCreated: (c) => c.addJavaScriptHandler(
      handlerName: 'probe',
      callback: (_) {
        called = true;
        return null;
      },
    ),
  );
  try {
    await t.js("window.flutter_inappwebview.callHandler('probe'); true;");
    await settle(tester, const Duration(seconds: 1));
    return called;
  } finally {
    await t.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(LinuxInAppWebViewPlatform.registerWith);

  // S1. Allow list control: the allowed origin itself must work, otherwise
  // the red cases below prove nothing.
  testWidgets('S1-control allowed origin reaches the handler', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(await handlerReachableFrom(tester, 'https://example.com/'), isTrue);
  });

  // S1. Substring match: a different host that starts with the allowed one.
  testWidgets('S1 allow list rejects a look-alike host', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(
      await handlerReachableFrom(tester, 'https://example.com.evil.test/'),
      isFalse,
    );
  });

  // S1b. Userinfo: the real host is evil.test.
  testWidgets('S1b allow list rejects userinfo tricks', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(
      await handlerReachableFrom(tester, 'https://example.com@evil.test/'),
      isFalse,
    );
  });

  // S1c. Port: a different port is a different origin.
  testWidgets('S1c allow list rejects another port', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(
      await handlerReachableFrom(tester, 'https://example.com:8443/'),
      isFalse,
    );
  });

  // S2. Page JS calls an internal handler name and fakes a console event.
  testWidgets('S2 page JS cannot spoof internal events', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      await t.js('''window.flutter_inappwebview.callHandler('onConsoleMessage',
  {level: 'error', message: 'spoofed-by-page'}); true;''');
      await settle(tester, const Duration(seconds: 1));
      expect(t.console, isNot(contains('spoofed-by-page')));
    } finally {
      await t.dispose();
    }
  });

  // S2 control: real console messages and color inputs still reach Dart,
  // otherwise S2 and S5 pass for the wrong reason.
  testWidgets('S2-control real console messages still arrive', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      await t.js("console.log('real-message'); true;");
      await waitFor(
        tester,
        () => t.console.contains('real-message'),
        reason: 'console message',
      );
    } finally {
      await t.dispose();
    }
  });

  // S2b. No plugin function that page JS can reach shows the internal call
  // function's name in its source.
  testWidgets('S2b internal call name does not leak through toString', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      final sources = await t.js('''[console.log, console.error, window.print,
  window.flutter_inappwebview.callHandler].map(String).join('\\n')''');
      expect(sources, isA<String>());
      expect(sources, isNot(contains('_fiw_')));
    } finally {
      await t.dispose();
    }
  });

  // N1. Origin allow lists of scripts are enforced: the bridge, plugin
  // scripts and user scripts run only on allowed origins.
  Future<dynamic> probeAt(
    WidgetTester tester,
    String baseUrl,
    InAppWebViewSettings settings,
    String expression,
  ) async {
    final t = await TestView.start(
      tester,
      baseUrl: baseUrl,
      settings: settings,
    );
    try {
      return await t.js(expression);
    } finally {
      await t.dispose();
    }
  }

  const bridgeType = 'typeof window.flutter_inappwebview';

  testWidgets('N1a-control bridge runs on an allowed origin', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final settings = InAppWebViewSettings(
      javaScriptBridgeOriginAllowList: {'https://example.com'},
    );
    expect(
      await probeAt(tester, 'https://example.com/', settings, bridgeType),
      'object',
    );
  });

  testWidgets('N1a bridge allow list keeps the bridge off other origins', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final settings = InAppWebViewSettings(
      javaScriptBridgeOriginAllowList: {'https://example.com'},
    );
    for (final url in [
      'https://example.com.evil.test/',
      'https://example.com:8443/',
      'http://example.com/',
    ]) {
      expect(await probeAt(tester, url, settings, bridgeType), 'undefined');
    }
  });

  testWidgets('N1b plugin scripts allow list applies to all plugin scripts', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final settings = InAppWebViewSettings(
      pluginScriptsOriginAllowList: {'https://example.com'},
    );
    // The bridge falls back to this list; console.log stays native.
    expect(
      await probeAt(
        tester,
        'https://evil.test/',
        settings,
        "$bridgeType + ' ' + /\\[native code\\]/.test(String(console.log))",
      ),
      'undefined true',
    );
  });

  testWidgets('N1c an empty bridge allow list turns the bridge off', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final settings = InAppWebViewSettings(javaScriptBridgeOriginAllowList: {});
    expect(
      await probeAt(tester, 'https://example.com/', settings, bridgeType),
      'undefined',
    );
  });

  testWidgets('N1d user script allowedOriginRules are enforced', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      await t.controller.addUserScript(
        userScript: UserScript(
          source: 'window.__n1 = (window.__n1 || 0) + 1;',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          allowedOriginRules: {'https://example.com'},
        ),
      );
      final results = <String, dynamic>{};
      for (final url in [
        'https://example.com:8443/',
        'https://example.com.evil.test/',
        'https://example.com/',
      ]) {
        final stops = t.loadStops.length;
        await t.controller.loadData(data: plainPage, baseUrl: WebUri(url));
        await waitFor(
          tester,
          () => t.loadStops.length > stops,
          reason: 'load $url',
        );
        results[url] = await t.js('String(window.__n1)');
      }
      expect(results, {
        'https://example.com:8443/': 'undefined',
        'https://example.com.evil.test/': 'undefined',
        'https://example.com/': '1',
      });
    } finally {
      await t.dispose();
    }
  });

  // S5b. A click() from page JS is not a user gesture either.
  testWidgets('S5b scripted click does not open the color dialog', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    if (await skipWithoutHooks()) return;
    final t = await TestView.start(
      tester,
      html: '<!doctype html><input type="color" id="c">',
    );
    try {
      await t.js("document.getElementById('c').click(); true;");
      await settle(tester, const Duration(seconds: 1));
      final open = await Hooks.dialogs();
      for (final kind in open) {
        await Hooks.respond(kind, ok: false);
      }
      expect(open, isEmpty);
    } finally {
      await t.dispose();
    }
  });

  // S3. _windowId comes from the message body (page-writable global), and
  // picks the target view. Today the target popup has no channel (W19), so
  // nothing reaches Dart and this passes; once popups work it is live. A page in one view routes a JS-handler call
  // into a popup window's Dart handler.
  testWidgets('S3 page cannot route bridge calls into another window', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final popupCalls = <String>[];
    int? popupWindowId;
    LinuxHeadlessInAppWebView? popup;
    final opener = await TestView.start(
      tester,
      settings: InAppWebViewSettings(
        javaScriptCanOpenWindowsAutomatically: true,
        supportMultipleWindows: true,
      ),
      onCreateWindow: (_, action) async {
        popupWindowId = action.windowId;
        popup = LinuxHeadlessInAppWebView(
          LinuxHeadlessInAppWebViewCreationParams(
            windowId: action.windowId,
            initialSize: const Size(200, 200),
            onWebViewCreated: (c) => c.addJavaScriptHandler(
              handlerName: 'popupOnly',
              callback: (args) {
                popupCalls.add('${args.isEmpty ? '' : args.first}');
                return null;
              },
            ),
          ),
        );
        await popup!.run();
        return true;
      },
    );
    // A separate, unrelated view (another site).
    final attacker = await TestView.start(
      tester,
      baseUrl: 'https://attacker.test/',
    );
    try {
      await opener.js("window.open('about:blank'); true;");
      await waitFor(tester, () => popupWindowId != null, reason: 'popup');
      await settle(tester, const Duration(seconds: 1));
      await attacker.js(
        '''window._flutter_inappwebview_windowId = $popupWindowId;
window.flutter_inappwebview.callHandler('popupOnly', 'from-attacker'); true;''',
      );
      await settle(tester, const Duration(seconds: 1));
      expect(popupCalls, isNot(contains('from-attacker')));
    } finally {
      await attacker.dispose();
      await popup?.dispose();
      await opener.dispose();
    }
  });

  // S4a. Permission origin: must be the origin, not the full page URL with
  // path and query. Needs W18 fixed (permission events never reach Dart).
  testWidgets('S4a permission request reports the origin', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    final origins = <String>[];
    final t = await TestView.start(
      tester,
      url: server.url('/some/page?secret=1'),
      onPermissionRequest: (_, r) async {
        origins.add(r.origin.toString());
        return PermissionResponse(action: PermissionResponseAction.DENY);
      },
    );
    try {
      await t.js('Notification.requestPermission(); true;');
      await waitFor(
        tester,
        () => origins.isNotEmpty,
        reason: 'permission request',
      );
      expect(origins.single, anyOf(server.url(''), '${server.url('')}/'));
    } finally {
      await t.dispose();
      await server.close();
    }
  });

  // S4b. An iframe from another origin asks; the request is attributed to
  // the top page. Needs W18 fixed.
  testWidgets('S4b iframe permission request reports the iframe origin', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final top = await LocalServer.start();
    final other = await LocalServer.start();
    other.handlers['/frame'] = (r, _) {
      r.response
        ..headers.set('content-type', 'text/html')
        ..write('<script>Notification.requestPermission();</script>');
    };
    top.handlers['/top'] = (r, _) {
      r.response
        ..headers.set('content-type', 'text/html')
        ..write('<iframe src="${other.url('/frame')}"></iframe>');
    };
    final origins = <String>[];
    final t = await TestView.start(
      tester,
      url: top.url('/top'),
      onPermissionRequest: (_, r) async {
        origins.add(r.origin.toString());
        return PermissionResponse(action: PermissionResponseAction.DENY);
      },
    );
    try {
      await waitFor(
        tester,
        () => origins.isNotEmpty,
        reason: 'iframe permission request',
      );
      expect(origins.single, startsWith(other.url('')));
    } finally {
      await t.dispose();
      await top.close();
      await other.close();
    }
  });

  // S5. Page JS opens a native color dialog with no user gesture.
  testWidgets('S5 page JS cannot open native dialogs without a gesture', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    if (await skipWithoutHooks()) return;
    final t = await TestView.start(tester);
    try {
      await t.js(
        '''window.flutter_inappwebview.callHandler('_onColorInputClicked',
  {currentColor: '#000000', elemRect: {x:0,y:0,width:10,height:10},
   predefinedColors: [], alphaEnabled: false, colorSpace: 'limited-srgb'}); true;''',
      );
      await settle(tester, const Duration(seconds: 1));
      final open = await Hooks.dialogs();
      for (final kind in open) {
        await Hooks.respond(kind, ok: false);
      }
      expect(open, isEmpty);
    } finally {
      await t.dispose();
    }
  });

  // S8a. injectJavascriptFileFromUrl splices the URL into a JS string: a
  // quote in the URL breaks out and runs code.
  testWidgets('S8a injectJavascriptFileFromUrl does not run URL text as code', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      await t.js('window.__pwned = false; true;');
      await t.controller.injectJavascriptFileFromUrl(
        urlFile: WebUri("https://example.com/a.js?x=';window.__pwned=true;'"),
      );
      await settle(tester, const Duration(milliseconds: 500));
      expect(await t.js('window.__pwned'), isFalse);
    } finally {
      await t.dispose();
    }
  });

  // S8b. injectCSSCode escapes only ' and \n, not backslashes. Valid CSS
  // with an escaped quote (content: '\'') becomes a JS syntax error and is
  // silently dropped. (Checked offline: this cannot be turned into code
  // execution, because a break-out always leaves an unpaired quote.)
  testWidgets('S8b injectCSSCode applies CSS with an escaped quote', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      await t.controller.injectCSSCode(
        source: r"body::after { content: '\''; } body { color: rgb(4, 5, 6); }",
      );
      await settle(tester, const Duration(milliseconds: 500));
      expect(
        await t.js('getComputedStyle(document.body).color'),
        'rgb(4, 5, 6)',
      );
    } finally {
      await t.dispose();
    }
  });

  // S8c. A CSS value with a carriage return is a JS syntax error today, so
  // valid CSS is silently dropped.
  testWidgets('S8c injectCSSCode applies CSS containing a carriage return', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      await t.controller.injectCSSCode(
        source: 'body {\r\n  color: rgb(1, 2, 3);\r\n}',
      );
      await settle(tester, const Duration(milliseconds: 500));
      expect(
        await t.js('getComputedStyle(document.body).color'),
        'rgb(1, 2, 3)',
      );
    } finally {
      await t.dispose();
    }
  });

  // S8d. injectCSSFileFromUrl: same unescaped splice as S8a.
  testWidgets('S8d injectCSSFileFromUrl does not run URL text as code', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      await t.js('window.__pwned = false; true;');
      await t.controller.injectCSSFileFromUrl(
        urlFile: WebUri("https://example.com/a.css?x=';window.__pwned=true;'"),
      );
      await settle(tester, const Duration(milliseconds: 500));
      expect(await t.js('window.__pwned'), isFalse);
    } finally {
      await t.dispose();
    }
  });

  // S9. Pointer lock: no code sets pointer_lock_handler_, so
  // OnPointerLockRequest allows every request. A page can capture the
  // pointer without the app agreeing. Needs a user gesture in WebKit, so
  // this uses the visible widget and a real click.
  testWidgets('S9 page cannot lock the pointer without the app', (
    tester,
  ) async {
    final created = Completer<LinuxInAppWebViewController>();
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
                    data: '''<!doctype html><body style="height:100vh;margin:0">
<script>window.__locked = 'none'; window.__down = false;
document.addEventListener('pointerlockchange', () => window.__locked = String(!!document.pointerLockElement));
document.addEventListener('pointerlockerror', () => window.__locked = 'error');
document.body.addEventListener('mousedown', () => { window.__down = true; document.body.requestPointerLock(); });
</script></body>''',
                    baseUrl: WebUri('https://example.com/'),
                  ),
                  onWebViewCreated: (c) {
                    if (!created.isCompleted) {
                      created.complete(c as LinuxInAppWebViewController);
                    }
                  },
                ),
              ).build(context),
            ),
          ),
        ),
      ),
    );
    final controller = await created.future.timeout(
      const Duration(seconds: 20),
    );
    await settle(tester, const Duration(seconds: 2));
    await tester.tapAt(tester.getCenter(find.byType(SizedBox).last));
    await settle(tester, const Duration(seconds: 1));
    expect(
      await controller.evaluateJavascript(source: 'window.__down'),
      isTrue,
      reason: 'precondition: the click did not reach the page',
    );
    await settle(tester, const Duration(seconds: 1));
    final locked = await controller.evaluateJavascript(
      source: 'window.__locked',
    );
    debugPrint('REVIEW: S9 locked=$locked');
    expect(locked, isNot('true'));
  });
}
