// Red tests for the wrong-behavior findings in REVIEW_in_app_webview.md,
// section 3. Each asserts the documented (correct) behavior; on the
// reviewed pin each fails. Run one test per process (--plain-name "W3a ").

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_linux/flutter_inappwebview_linux.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'review_common.dart';

/// A visible view (texture + real pointer and key input), for tests that
/// need user gestures or keyboard input.
Future<LinuxInAppWebViewController> pumpVisible(
  WidgetTester tester, {
  required String html,
  ContextMenu? contextMenu,
  void Function(String?)? onLoadStop,
}) async {
  final created = Completer<LinuxInAppWebViewController>();
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
                  data: html,
                  baseUrl: WebUri('https://example.com/'),
                ),
                contextMenu: contextMenu,
                onWebViewCreated: (c) {
                  if (!created.isCompleted) {
                    created.complete(c as LinuxInAppWebViewController);
                  }
                },
                onLoadStop: (_, u) {
                  onLoadStop?.call(u?.toString());
                  if (!loaded.isCompleted) loaded.complete();
                },
              ),
            ).build(context),
          ),
        ),
      ),
    ),
  );
  final controller = await created.future.timeout(const Duration(seconds: 20));
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!loaded.isCompleted && DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  await settle(tester, const Duration(milliseconds: 500));
  return controller;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(LinuxInAppWebViewPlatform.registerWith);

  // W1. Custom context-menu item ids share the stock-action id space: a
  // custom item with id 12 (WEBKIT_CONTEXT_MENU_ACTION_RELOAD) reloads the
  // page before Dart hears about the click.
  testWidgets('W1 custom context-menu item runs only its own action', (
    tester,
  ) async {
    if (await skipWithoutHooks()) return;
    final clicked = <dynamic>[];
    var loads = 0;
    final controller = await pumpVisible(
      tester,
      html: '<!doctype html><body style="height:100vh;margin:0">x</body>',
      onLoadStop: (_) => loads++,
      contextMenu: ContextMenu(
        settings: ContextMenuSettings(hideDefaultSystemContextMenuItems: true),
        menuItems: [ContextMenuItem(id: 12, title: 'Mine')],
        onContextMenuActionItemClicked: (item) => clicked.add(item.id),
      ),
    );
    await controller.evaluateJavascript(source: 'window.__marker = 1; true;');
    final loadsBefore = loads;
    final center = tester.getCenter(find.byType(SizedBox).last);
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await settle(tester, const Duration(milliseconds: 100));
    await gesture.up();
    await settle(tester, const Duration(seconds: 1));
    expect(
      await Hooks.popupVisible(),
      isTrue,
      reason: 'context menu did not open',
    );
    expect(await Hooks.clickPopupItem(0, 'i'), isTrue);
    await settle(tester, const Duration(seconds: 2));
    // Dart gets the id back as a String (W1b). Compare loosely here so the
    // test reaches its real check: did the page reload?
    expect(clicked.map((e) => '$e'), ['12'], reason: 'click not reported');
    expect(loads, loadsBefore, reason: 'custom item reloaded the page');
    expect(await controller.evaluateJavascript(source: 'window.__marker'), 1);
  });

  // W1b. A custom item's int id comes back to Dart as a String.
  testWidgets('W1b custom context-menu item keeps its id type', (tester) async {
    if (await skipWithoutHooks()) return;
    final clicked = <dynamic>[];
    await pumpVisible(
      tester,
      html: '<!doctype html><body style="height:100vh;margin:0">x</body>',
      contextMenu: ContextMenu(
        settings: ContextMenuSettings(hideDefaultSystemContextMenuItems: true),
        menuItems: [ContextMenuItem(id: 4242, title: 'Mine')],
        onContextMenuActionItemClicked: (item) => clicked.add(item.id),
      ),
    );
    final center = tester.getCenter(find.byType(SizedBox).last);
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await settle(tester, const Duration(milliseconds: 100));
    await gesture.up();
    await settle(tester, const Duration(seconds: 1));
    expect(
      await Hooks.popupVisible(),
      isTrue,
      reason: 'context menu did not open',
    );
    expect(await Hooks.clickPopupItem(0, 'i'), isTrue);
    await settle(tester, const Duration(seconds: 1));
    expect(clicked, [4242]);
  });

  // W2. download-started is connected on the shared network session by
  // every view. A view with downloads off cancels other views' downloads,
  // and each enabled view hears about every download.
  //
  // Needs C3 fixed: today the enabled view's own cancel crashes WebKit
  // first, so this test crashes instead of failing.
  testWidgets('W2a a view with downloads off does not cancel others', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final name = 'tnx-review-${DateTime.now().microsecondsSinceEpoch}.bin';
    final asked = <String>[];
    final off = await TestView.start(tester);
    final on = await TestView.start(
      tester,
      settings: InAppWebViewSettings(useOnDownloadStart: true),
      onDownloadStarting: (_, _) async {
        asked.add('on');
        return DownloadStartResponse(
          handled: true,
          action: DownloadStartResponseAction.CANCEL,
        );
      },
    );
    try {
      await on.js(
        "const l = document.createElement('a');"
        "l.href = URL.createObjectURL(new Blob(['x'], {type: 'application/octet-stream'}));"
        "l.download = '$name'; document.body.appendChild(l); l.click(); true;",
      );
      await settle(tester, const Duration(seconds: 3));
      expect(asked, [
        'on',
      ], reason: 'the view that enabled downloads was never asked');
    } finally {
      final f = File('${Platform.environment['HOME']}/Downloads/$name');
      if (f.existsSync()) f.deleteSync();
      await on.dispose();
      await off.dispose();
    }
  });

  // W3a. alert() handled by the client: the dialog is never closed, so the
  // page's alert() never returns.
  testWidgets('W3a alert handled by the client returns to the page', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(
      tester,
      onJsAlert: (_, _) async => JsAlertResponse(handledByClient: true),
    );
    try {
      await t.js(
        "window.__after = false; setTimeout(() => { alert('hi'); window.__after = true; }, 0); true;",
      );
      await settle(tester, const Duration(seconds: 2));
      // A stuck alert() also blocks evaluateJavascript, so bound it.
      final after = await t
          .js('window.__after')
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => 'page blocked in alert()',
          );
      expect(after, isTrue);
    } finally {
      await t.dispose();
    }
  });

  // W3b. confirm(): Dart's JsConfirmResponseAction has CONFIRM=0, CANCEL=1;
  // native reads CANCEL=0, CONFIRM=1. Every answer is inverted.
  testWidgets('W3b confirm returns the client answer', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(
      tester,
      onJsConfirm: (_, _) async => JsConfirmResponse(
        handledByClient: true,
        action: JsConfirmResponseAction.CONFIRM,
      ),
    );
    try {
      await t.js("setTimeout(() => { window.__c = confirm('q'); }, 0); true;");
      await settle(tester, const Duration(seconds: 2));
      expect(await t.js('window.__c'), isTrue);
    } finally {
      await t.dispose();
    }
  });

  // W3c. prompt(): same enum inversion as confirm.
  testWidgets('W3c prompt returns the client answer', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(
      tester,
      onJsPrompt: (_, _) async => JsPromptResponse(
        handledByClient: true,
        action: JsPromptResponseAction.CONFIRM,
        value: 'answer',
      ),
    );
    try {
      await t.js("setTimeout(() => { window.__p = prompt('q'); }, 0); true;");
      await settle(tester, const Duration(seconds: 2));
      expect(await t.js('window.__p'), 'answer');
    } finally {
      await t.dispose();
    }
  });

  // W3d. beforeunload: the client says "stay"; the navigation must not
  // happen.
  testWidgets('W3d beforeunload honors the client answer', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    var asked = 0;
    final t = await TestView.start(
      tester,
      onJsBeforeUnload: (_, _) async {
        asked++;
        return JsBeforeUnloadResponse(
          handledByClient: true,
          action: JsBeforeUnloadResponseAction.CANCEL,
        );
      },
    );
    try {
      await t.js(
        "window.__stay = 1; window.addEventListener('beforeunload', e => { e.preventDefault(); e.returnValue = 'x'; }); true;",
      );
      // beforeunload prompts need a prior user interaction in WebKit.
      await t.controller.loadUrl(
        urlRequest: URLRequest(url: WebUri('https://example.com/other')),
      );
      await settle(tester, const Duration(seconds: 2));
      if (asked == 0) {
        markTestSkipped('WebKit did not ask (needs a user gesture first)');
        return;
      }
      expect(await t.js('window.__stay'), 1);
    } finally {
      await t.dispose();
    }
  });

  // W4. <input type=week>: ISO week numbering year. 2024-12-30 is a Monday
  // in ISO week 1 of 2025.
  testWidgets('W4 week input uses the ISO week-numbering year', (tester) async {
    if (await skipWithoutHooks()) return;
    // A real tap opens the dialog: page JS cannot (S5). The date script
    // opens it for a tap on the right 30 px of the input.
    final c = await pumpVisible(
      tester,
      html:
          '<!doctype html><body style="margin:0"><input type="week" id="w" '
          'value="2024-W50" style="width:100vw;height:100vh;box-sizing:border-box">',
    );
    await tester.tapAt(
      tester.getCenter(find.byType(SizedBox).last) + const Offset(290, 0),
    );
    await settle(tester, const Duration(seconds: 1));
    expect(await Hooks.setCalendarDate(2024, 12, 30), isTrue);
    expect(await Hooks.respond('', ok: true), isTrue);
    await settle(tester, const Duration(seconds: 1));
    expect(
      await c.evaluateJavascript(source: "document.getElementById('w').value"),
      '2025-W01',
    );
  });

  // W5a. loadUrl with a POST URLRequest: method and body are dropped.
  testWidgets('W5a loadUrl sends the request method and body', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    final t = await TestView.start(tester);
    try {
      await t.controller.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(server.url('/form')),
          method: 'POST',
          body: Uint8List.fromList(utf8.encode('a=1')),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        ),
      );
      await waitFor(
        tester,
        () => server.requests.any((r) => r.uri.startsWith('/form')),
        reason: 'request',
      );
      final r = server.requests.firstWhere((r) => r.uri.startsWith('/form'));
      expect(r.method, 'POST');
      expect(utf8.decode(r.body), 'a=1');
    } finally {
      await t.dispose();
      await server.close();
    }
  });

  // W5b. postUrl: the body is sent through XHR as a JS string, so bytes >= 0x80
  // are UTF-8 encoded; and the response is not shown as a page.
  testWidgets('W5b postUrl sends raw bytes and shows the response page', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    server.handlers['/post'] = (r, _) {
      r.response
        ..headers.set('content-type', 'text/html')
        ..write('<title>posted</title>ok');
    };
    final t = await TestView.start(tester);
    try {
      final bytes = Uint8List.fromList([0x61, 0x3d, 0xe9, 0xff, 0x00, 0x80]);
      await t.controller.postUrl(
        url: WebUri(server.url('/post')),
        postData: bytes,
      );
      await waitFor(
        tester,
        () => server.requests.any((r) => r.uri == '/post'),
        reason: 'post',
      );
      await settle(tester, const Duration(seconds: 1));
      final r = server.requests.firstWhere((r) => r.uri == '/post');
      expect(r.body, bytes);
      expect(await t.js('document.title'), 'posted');
    } finally {
      await t.dispose();
      await server.close();
    }
  });

  // W5c. loadFile builds "file://" + path without percent-encoding: a
  // space or '#' in the asset path breaks the URL.
  testWidgets('W5c loadFile handles reserved characters in the path', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final dir = Directory('$exeDir/data/flutter_assets/review #dir');
    dir.createSync(recursive: true);
    File('${dir.path}/page.html').writeAsStringSync('<title>asset ok</title>');
    final t = await TestView.start(tester);
    try {
      final before = t.loadStops.length;
      await t.controller.loadFile(assetFilePath: 'review #dir/page.html');
      await waitFor(
        tester,
        () => t.loadStops.length > before || t.errors.isNotEmpty,
        reason: 'load',
      );
      await settle(tester, const Duration(milliseconds: 500));
      expect(await t.js('document.title'), 'asset ok');
    } finally {
      await t.dispose();
      dir.deleteSync(recursive: true);
    }
  });

  // W6a. shouldOverrideUrlLoading for a form POST reports GET.
  testWidgets('W6a navigation action reports the POST method', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    final methods = <String?>[];
    final t = await TestView.start(
      tester,
      url: server.url('/start'),
      settings: InAppWebViewSettings(useShouldOverrideUrlLoading: true),
      shouldOverrideUrlLoading: (_, a) async {
        if (a.request.url.toString().contains('/submit')) {
          methods.add(a.request.method);
        }
        return NavigationActionPolicy.ALLOW;
      },
    );
    try {
      await t.js('''const f = document.createElement('form'); f.method = 'POST';
f.action = '/submit'; const i = document.createElement('input'); i.name = 'a'; i.value = '1';
f.appendChild(i); document.body.appendChild(f); f.submit(); true;''');
      await waitFor(
        tester,
        () => methods.isNotEmpty,
        reason: 'navigation action',
      );
      expect(methods.single, 'POST');
    } finally {
      await t.dispose();
      await server.close();
    }
  });

  // W6b. An unnamed iframe's navigation is reported as main frame (the
  // code guesses from the target frame name).
  testWidgets('W6b iframe navigation is not reported as main frame', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    final mainFrame = <bool?>[];
    final t = await TestView.start(
      tester,
      url: server.url('/top'),
      settings: InAppWebViewSettings(useShouldOverrideUrlLoading: true),
      shouldOverrideUrlLoading: (_, a) async {
        if (a.request.url.toString().contains('/inner')) {
          mainFrame.add(a.isForMainFrame);
        }
        return NavigationActionPolicy.ALLOW;
      },
    );
    try {
      await t.js(
        "const f = document.createElement('iframe'); f.src = '/inner'; document.body.appendChild(f); true;",
      );
      await waitFor(
        tester,
        () => mainFrame.isNotEmpty,
        reason: 'iframe navigation',
      );
      expect(mainFrame.single, isFalse);
    } finally {
      await t.dispose();
      await server.close();
    }
  });

  // W6c. stopLoading / a new navigation reports the cancelled load as an
  // error.
  testWidgets('W6c a cancelled load is not reported as an error', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    final slow = Completer<void>();
    server.handlers['/slow'] = (r, _) async {
      await slow.future.timeout(const Duration(seconds: 10), onTimeout: () {});
      r.response.write('late');
    };
    final t = await TestView.start(tester);
    try {
      final before = t.errors.length;
      await t.controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(server.url('/slow'))),
      );
      await waitFor(
        tester,
        () => server.requests.any((r) => r.uri == '/slow'),
        reason: 'slow request',
      );
      await t.controller.stopLoading();
      await settle(tester, const Duration(seconds: 1));
      expect(t.errors.skip(before).map((e) => e.description), isEmpty);
    } finally {
      slow.complete();
      await t.dispose();
      await server.close();
    }
  });

  // W7. setSettings(javaScriptBridgeEnabled: false) at runtime: the bridge
  // is still there.
  testWidgets('W7 disabling the JS bridge at runtime removes it', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      expect(await t.js('typeof window.flutter_inappwebview'), 'object');
      final s = await t.controller.getSettings() ?? InAppWebViewSettings();
      s.javaScriptBridgeEnabled = false;
      await t.controller.setSettings(settings: s);
      await t.controller.reload();
      await settle(tester, const Duration(seconds: 2));
      expect(await t.js('typeof window.flutter_inappwebview'), 'undefined');
    } finally {
      await t.dispose();
    }
  });

  // W8. Ctrl+A key-down never reaches the page: the plugin swallows it and
  // runs a WebKit editing command instead.
  testWidgets('W8 page sees Ctrl+A keydown', (tester) async {
    final controller = await pumpVisible(
      tester,
      html:
          '''<!doctype html><body style="height:100vh;margin:0"><input id="i" autofocus>
<script>window.__keys = [];
document.addEventListener('keydown', e => window.__keys.push((e.ctrlKey ? 'C-' : '') + e.key));
</script></body>''',
    );
    await tester.tapAt(tester.getCenter(find.byType(SizedBox).last));
    await settle(tester, const Duration(milliseconds: 500));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await settle(tester, const Duration(seconds: 1));
    final keys =
        (await controller.evaluateJavascript(source: 'window.__keys') as List)
            .cast<String>();
    expect(
      keys,
      contains('b'),
      reason: 'control: plain key must arrive ($keys)',
    );
    expect(keys, contains('C-a'));
  });

  // W8b. Ctrl+Shift+Z: the shortcut table matches lowercase keysyms only;
  // with Shift the keysym is 'Z' (0x5a), so redo never runs.
  testWidgets('W8b Ctrl+Shift+Z redoes', (tester) async {
    final controller = await pumpVisible(
      tester,
      html:
          '<!doctype html><body style="height:100vh;margin:0"><input id="i" autofocus></body>',
    );
    await tester.tapAt(tester.getCenter(find.byType(SizedBox).last));
    await settle(tester, const Duration(milliseconds: 500));
    await controller.evaluateJavascript(
      source:
          "const i = document.getElementById('i'); i.focus(); document.execCommand('insertText', false, 'abc'); true;",
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester, const Duration(milliseconds: 500));
    final afterUndo = await controller.evaluateJavascript(
      source: "document.getElementById('i').value",
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    // A real keyboard reports 'Z' with Shift held; the test framework
    // would send 'z' unless told.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ, character: 'Z');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester, const Duration(milliseconds: 500));
    final final_ = await controller.evaluateJavascript(
      source: "document.getElementById('i').value",
    );
    debugPrint('REVIEW: W8b afterUndo=$afterUndo final=$final_');
    expect(afterUndo, '', reason: 'control: Ctrl+Z must undo');
    expect(
      await controller.evaluateJavascript(
        source: "document.getElementById('i').value",
      ),
      'abc',
    );
  });

  // W9. takeScreenshot feeds straight RGBA into Cairo's premultiplied ARGB32,
  // so translucent pixels come out wrong. A transparent page with a 50%
  // red box: Cairo treats (255,0,0,128) as premultiplied, which is not a
  // valid premultiplied pixel, and the PNG gets a too-bright red. Opaque
  // pixels are unaffected (control).
  testWidgets('W9 screenshot keeps translucent colors', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(
      tester,
      settings: InAppWebViewSettings(transparentBackground: true),
      html:
          '<!doctype html><html style="background:transparent"><body style="margin:0;background:transparent">'
          '<div style="width:50vw;height:100vh;background:rgb(0,0,255)"></div>'
          '<div style="position:absolute;left:50vw;top:0;width:50vw;height:100vh;'
          'background:rgba(255,0,0,0.5)"></div></body></html>',
    );
    try {
      await settle(tester, const Duration(seconds: 1));
      final png = await t.controller.takeScreenshot();
      expect(png, isNotNull, reason: 'no screenshot');
      final codec = await ui.instantiateImageCodec(png!);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      final w = frame.image.width, h = frame.image.height;
      List<int> at(int x, int y) {
        final o = (y * w + x) * 4;
        return [for (var k = 0; k < 4; k++) data!.getUint8(o + k)];
      }

      final opaque = at(w ~/ 4, h ~/ 2);
      final half = at(3 * w ~/ 4, h ~/ 2);
      debugPrint('REVIEW: opaque=$opaque half=$half');
      expect(opaque, [0, 0, 255, 255], reason: 'control: opaque pixel');
      // Straight RGBA of a 50% red over transparent: (255, 0, 0, ~128).
      expect(half[0], greaterThan(240));
      expect(half[3], inInclusiveRange(118, 138));
    } finally {
      await t.dispose();
    }
  });

  // W10. Each incognito view leaks one ephemeral WebKitNetworkSession.
  testWidgets('W10 incognito views release their network session', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    if (await skipWithoutHooks()) return;
    await warmUpWebKit(tester);
    final before = await Hooks.instanceCount('WebKitNetworkSession');
    for (var i = 0; i < 3; i++) {
      final t = await TestView.start(
        tester,
        settings: InAppWebViewSettings(incognito: true),
      );
      await t.dispose();
      await settle(tester, const Duration(milliseconds: 500));
    }
    await settle(tester, const Duration(seconds: 2));
    final created = await Hooks.instanceCount(
      'WebKitNetworkSession',
      created: true,
    );
    final after = await Hooks.instanceCount('WebKitNetworkSession');
    debugPrint(
      'REVIEW: WebKitNetworkSession before=$before after=$after created=$created',
    );
    expect(
      created,
      greaterThanOrEqualTo(3),
      reason: 'precondition: incognito views did not create sessions',
    );
    expect(after, before);
  });

  // W11. getCopyBackForwardList: WebKit's back list is nearest-first; the
  // code indexes it from 0 as if oldest-first.
  testWidgets('W11 back-forward list is in history order', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    final t = await TestView.start(tester, url: server.url('/one'));
    try {
      for (final p in ['/two', '/three']) {
        final n = t.loadStops.length;
        await t.controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(server.url(p))),
        );
        await waitFor(tester, () => t.loadStops.length > n, reason: p);
      }
      final h = await t.controller.getCopyBackForwardList();
      final urls = h!.list!
          .map((i) => Uri.parse(i.url.toString()).path)
          .toList();
      expect(urls, ['/one', '/two', '/three']);
      expect(h.currentIndex, 2);
    } finally {
      await t.dispose();
      await server.close();
    }
  });

  // W12. window.open with javaScriptCanOpenWindowsAutomatically off: the
  // popup URL loads in the current view instead of being blocked.
  testWidgets('W12 blocked popup does not navigate the opener', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(
      tester,
      settings: InAppWebViewSettings(
        javaScriptCanOpenWindowsAutomatically: false,
      ),
    );
    try {
      await t.js(
        "window.__still = 1; window.open('https://example.com/popup'); true;",
      );
      await settle(tester, const Duration(seconds: 2));
      expect(await t.js('window.__still'), 1);
      expect(await t.controller.getUrl(), WebUri('https://example.com/'));
    } finally {
      await t.dispose();
    }
  });

  // W13. Custom scheme: an empty body is reported as "not found".
  testWidgets('W13 custom scheme empty body is a successful empty response', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(
      tester,
      settings: InAppWebViewSettings(resourceCustomSchemes: ['tnxempty']),
      onLoadResourceWithCustomScheme: (_, _) async =>
          CustomSchemeResponse(contentType: 'text/plain', data: Uint8List(0)),
    );
    try {
      final r = await t.asyncJs(
        "try { const r = await fetch('tnxempty://x/'); return r.status + ':' + (await r.text()); }"
        " catch (e) { return 'error:' + e; }",
      );
      expect(r, '200:');
    } finally {
      await t.dispose();
    }
  });

  // W15. evaluateJavascript error JSON: a message with a control character
  // produces invalid JSON, so Dart gets no usable error/result.
  testWidgets('W15 evaluateJavascript survives control characters in errors', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      Object? error;
      try {
        await t.js(r"throw new Error('a\u0001b');");
      } catch (e) {
        error = e;
      }
      // Either an error carrying the message, or null; never a hang or a
      // crash. And the view must still answer afterwards.
      expect(error == null || '$error'.contains('a'), isTrue);
      expect(await t.js('1 + 1'), 2);
      // BigInt cannot be JSON-encoded: JSON.stringify throws inside the
      // plugin, leaving an exception on the JSC context.
      final big = await t.js('10n');
      expect(big, anyOf(isNull, 10, '10'));
      expect(await t.js('2 + 2'), 4);
    } finally {
      await t.dispose();
    }
  });

  // W16. HTTP auth: native sends previousFailureCount as null, Dart's
  // HttpAuthenticationChallenge.fromMap needs an int and throws, the plugin
  // cancels. Every 401 page fails to load.
  testWidgets('W16 HTTP basic auth logs in', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    final expected = 'Basic ${base64.encode(utf8.encode('u:p'))}';
    server.handlers['/auth'] = (r, _) {
      if (r.headers.value('authorization') == expected) {
        r.response
          ..headers.set('content-type', 'text/html')
          ..write('<title>in</title>');
      } else {
        r.response
          ..statusCode = 401
          ..headers.set('WWW-Authenticate', 'Basic realm="review"');
      }
    };
    var asked = 0;
    final t = await TestView.start(
      tester,
      onReceivedHttpAuthRequest: (_, _) async {
        asked++;
        return HttpAuthResponse(
          username: 'u',
          password: 'p',
          action: HttpAuthResponseAction.PROCEED,
        );
      },
    );
    try {
      final n = t.loadStops.length;
      await t.controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(server.url('/auth'))),
      );
      await waitFor(
        tester,
        () => t.loadStops.length > n || t.errors.isNotEmpty,
        reason: 'auth load',
      );
      await settle(tester, const Duration(milliseconds: 500));
      expect(asked, 1, reason: 'onReceivedHttpAuthRequest never ran');
      expect(await t.js('document.title'), 'in');
    } finally {
      await t.dispose();
      await server.close();
    }
  });

  // W17. TLS error: native sends SslError.code as a String, Dart wants an
  // int, the plugin cancels. The app is never asked.
  testWidgets('W17 TLS error reaches onReceivedServerTrustAuthRequest', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start(https: true);
    server.handlers['/tls'] = (r, _) {
      r.response
        ..headers.set('content-type', 'text/html')
        ..write('<title>tls ok</title>');
    };
    var asked = 0;
    final t = await TestView.start(
      tester,
      onReceivedServerTrustAuthRequest: (_, _) async {
        asked++;
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.PROCEED,
        );
      },
    );
    try {
      final n = t.loadStops.length;
      await t.controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(server.url('/tls'))),
      );
      await waitFor(
        tester,
        () => t.loadStops.length > n || t.errors.isNotEmpty,
        reason: 'tls load',
      );
      await settle(tester, const Duration(seconds: 1));
      expect(
        asked,
        greaterThanOrEqualTo(1),
        reason: 'onReceivedServerTrustAuthRequest never ran',
      );
      expect(await t.js('document.title'), 'tls ok');
    } finally {
      await t.dispose();
      await server.close();
    }
  });

  // W18. Permissions: PermissionResourceType has no Linux native values in
  // platform_interface 1.4.0-beta.3, so fromNativeValue returns null and the
  // event throws. Every request is denied.
  testWidgets('W18 granted notification permission reaches the page', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await LocalServer.start();
    final seen = <List<PermissionResourceType>>[];
    final t = await TestView.start(
      tester,
      url: server.url('/page'),
      onPermissionRequest: (_, r) async {
        seen.add(r.resources);
        return PermissionResponse(
          resources: r.resources,
          action: PermissionResponseAction.GRANT,
        );
      },
    );
    try {
      final result = await t.asyncJs(
        'return await Notification.requestPermission();',
      );
      expect(seen, isNotEmpty, reason: 'onPermissionRequest never ran');
      expect(seen.first, [PermissionResourceType.NOTIFICATIONS]);
      expect(result, 'granted');
    } finally {
      await t.dispose();
      await server.close();
    }
  });

  // W19. Popups: OnCreateWebView stores the popup's WebKitWebView in the
  // manager by windowId, but no code reads windowId when Dart creates the
  // popup view, so the popup is a fresh, unrelated, empty view.
  testWidgets('W19 a popup opened with window.open loads its URL', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    LinuxHeadlessInAppWebView? popup;
    final popupStops = <String?>[];
    final t = await TestView.start(
      tester,
      settings: InAppWebViewSettings(
        javaScriptCanOpenWindowsAutomatically: true,
        supportMultipleWindows: true,
      ),
      onCreateWindow: (_, action) async {
        popup = LinuxHeadlessInAppWebView(
          LinuxHeadlessInAppWebViewCreationParams(
            windowId: action.windowId,
            initialSize: const Size(200, 200),
            onLoadStop: (_, u) => popupStops.add(u?.toString()),
          ),
        );
        await popup!.run();
        return true;
      },
    );
    try {
      final opened = await t.js(
        "window.__w = window.open('https://example.com/popup'); String(window.__w !== null)",
      );
      await waitFor(tester, () => popup != null, reason: 'onCreateWindow');
      await settle(tester, const Duration(seconds: 3));
      expect(opened, 'true', reason: 'window.open returned null to the page');
      expect(popupStops, contains('https://example.com/popup'));
    } finally {
      await popup?.dispose();
      await t.dispose();
    }
  });

  // W21. A second color picker while one is open: the earlier reply is
  // unref'd without an answer, so the first input's promise never settles.
  testWidgets('W21 a second color picker settles the first one', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    if (await skipWithoutHooks()) return;
    final t = await TestView.start(tester);
    try {
      const open =
          """window.flutter_inappwebview.callHandler('_onColorInputClicked',
  {currentColor: '#000000', elemRect: {x:0,y:0,width:10,height:10},
   predefinedColors: [], alphaEnabled: false, colorSpace: 'limited-srgb'})""";
      await t.js(
        "window.__first = 'pending'; $open.then(r => window.__first = 'settled:' + r, e => window.__first = 'settled-error'); true;",
      );
      await settle(tester, const Duration(seconds: 1));
      await t.js("$open.then(r => window.__second = String(r)); true;");
      await settle(tester, const Duration(seconds: 1));
      for (final kind in await Hooks.dialogs()) {
        await Hooks.respond(kind, ok: false);
      }
      await settle(tester, const Duration(seconds: 1));
      expect(await t.js('window.__first'), startsWith('settled'));
    } finally {
      await t.dispose();
    }
  });

  // W22. callAsyncJavaScript splices argument keys into `const {...}`: a key
  // that is not a JS identifier is a SyntaxError.
  testWidgets('W22 callAsyncJavaScript accepts any argument key', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final t = await TestView.start(tester);
    try {
      final r = await t.controller.callAsyncJavaScript(
        functionBody: 'return arguments.length;',
        arguments: {'my-key': 1},
      );
      expect(r?.error, isNull);
    } finally {
      await t.dispose();
    }
  });

  // W23. addWebMessageListener: an allowed-origin rule with an IPv6 host
  // and port is mis-parsed (split at the first ':').
  testWidgets('W23 web message listener allows an IPv6 origin rule', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = HttpServer.bind(InternetAddress.loopbackIPv6, 0);
    final s = await server.catchError(
      (_) => throw StateError('no IPv6 loopback'),
    );
    s.listen((r) async {
      r.response
        ..headers.set('content-type', 'text/html')
        ..write('<title>v6</title>');
      await r.response.close();
    });
    final origin = 'http://[::1]:${s.port}';
    final got = <String>[];
    // Wait for the first page: a listener added while it is still loading
    // can miss the next document (a separate WebKit race).
    final t = await TestView.start(tester);
    try {
      await t.controller.addWebMessageListener(
        LinuxWebMessageListener(
          LinuxWebMessageListenerCreationParams(
            jsObjectName: 'reviewObj',
            allowedOriginRules: {origin},
            onPostMessage: (m, _, _, _) => got.add('${m?.data}'),
          ),
        ),
      );
      await t.controller.loadUrl(
        urlRequest: URLRequest(url: WebUri('$origin/')),
      );
      await waitFor(
        tester,
        () => t.loadStops.any((u) => u != null && u.startsWith(origin)),
        reason: 'IPv6 page load',
      );
      final has = await t.js('typeof reviewObj');
      if (has == 'object') {
        await t.js("reviewObj.postMessage('hi'); true;");
        await settle(tester, const Duration(seconds: 1));
      }
      expect(got, ['hi'], reason: 'reviewObj in page: $has');
    } finally {
      await t.dispose();
      await s.close(force: true);
    }
  });

  // W24. Context-menu "Download Linked File": webkit_web_view_download_uri
  // returns a new reference that is never released, so each download leaks
  // a WebKitDownload.
  testWidgets('W24 context-menu downloads do not leak', (tester) async {
    if (await skipWithoutHooks()) return;
    final name = 'tnx-review-${DateTime.now().microsecondsSinceEpoch}.bin';
    final server = await LocalServer.start();
    addTearDown(server.close);
    server.handlers['/file.bin'] = (r, _) {
      r.response
        ..headers.set('content-type', 'application/octet-stream')
        ..headers.set('content-disposition', 'attachment; filename="$name"')
        ..write('x');
    };
    final controller = await pumpVisible(
      tester,
      html:
          '<!doctype html><body style="margin:0">'
          '<a id="l" href="${server.url('/file.bin')}" '
          'style="display:block;width:100vw;height:100vh">link</a></body>',
    );
    final before = await Hooks.instanceCount('WebKitDownload');
    final createdBefore = await Hooks.instanceCount(
      'WebKitDownload',
      created: true,
    );
    final center = tester.getCenter(find.byType(SizedBox).last);
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await settle(tester, const Duration(milliseconds: 100));
    await gesture.up();
    await settle(tester, const Duration(seconds: 1));
    expect(
      await Hooks.popupVisible(),
      isTrue,
      reason: 'context menu did not open',
    );
    // Link menu: Open Link, Open in New Window, Download Linked File, Copy
    // Link Address. Row 2 is the download.
    expect(await Hooks.clickPopupItem(2, 'iiii'), isTrue);
    await settle(tester, const Duration(seconds: 3));
    final after = await Hooks.instanceCount('WebKitDownload');
    debugPrint('REVIEW: WebKitDownload before=$before after=$after');
    final f = File('${Platform.environment['HOME']}/Downloads/$name');
    final saved = f.existsSync();
    if (saved) f.deleteSync();
    final started =
        await Hooks.instanceCount('WebKitDownload', created: true) -
        createdBefore;
    debugPrint('REVIEW: W24 started=$started saved=$saved');
    // With useOnDownloadStart off the plugin cancels the download at once,
    // so nothing is saved; the object must still be released.
    expect(
      started,
      1,
      reason: 'precondition: the menu item did not start a download',
    );
    expect(after, before);
    expect(await controller.evaluateJavascript(source: '1 + 1'), 2);
  });
}
