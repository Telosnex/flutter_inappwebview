// Shared helpers for the review_*_test.dart red tests.
//
// Each test asserts the correct behavior, so it fails (or crashes) on the
// reviewed pin and passes once the finding is fixed. Run ONE test per
// process (`flutter test --plain-name "<ID> "`): a native crash ends the
// whole run. Use-after-free tests are reliable only in an ASan build; see
// REVIEW_in_app_webview.md, "Running the red tests".

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_linux/flutter_inappwebview_linux.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// A page that repaints every frame, so frames keep arriving.
const animatedPage = """<!doctype html><html><body style="margin:0">
<canvas id="c" width="300" height="200"></canvas><script>
const g = document.getElementById('c').getContext('2d');
let n = 0;
(function draw() {
  g.fillStyle = 'hsl(' + (n++ % 360) + ',80%,50%)';
  g.fillRect(0, 0, 300, 200);
  requestAnimationFrame(draw);
})();
</script></body></html>""";

const plainPage = '<!doctype html><html><body>x</body></html>';

/// Pumps frames and lets the platform run for [d].
Future<void> settle(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

/// Waits until [condition] is true, pumping frames; fails after [timeout].
Future<void> waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
  String reason = 'condition',
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('timed out waiting for $reason');
    }
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

/// A headless view with the usual test plumbing. Callbacks not set here are
/// passed through [params].
class TestView {
  TestView._(this.view);

  final LinuxHeadlessInAppWebView view;
  LinuxInAppWebViewController? _controller;
  final loadStops = <String?>[];
  final console = <String>[];
  final errors = <WebResourceError>[];
  bool disposed = false;

  LinuxInAppWebViewController get controller => _controller!;

  static Future<TestView> start(
    WidgetTester tester, {
    String? html,
    String baseUrl = 'https://example.com/',
    String? url,
    InAppWebViewSettings? settings,
    bool waitForLoad = true,
    int? windowId,
    void Function(LinuxInAppWebViewController controller)? onCreated,
    // Callbacks under test. Typed `dynamic` controller to stay platform-neutral.
    FutureOr<NavigationActionPolicy?> Function(dynamic, NavigationAction)?
    shouldOverrideUrlLoading,
    FutureOr<NavigationResponseAction?> Function(dynamic, NavigationResponse)?
    onNavigationResponse,
    FutureOr<JsAlertResponse?> Function(dynamic, JsAlertRequest)? onJsAlert,
    FutureOr<JsConfirmResponse?> Function(dynamic, JsConfirmRequest)?
    onJsConfirm,
    FutureOr<JsPromptResponse?> Function(dynamic, JsPromptRequest)? onJsPrompt,
    FutureOr<JsBeforeUnloadResponse?> Function(dynamic, JsBeforeUnloadRequest)?
    onJsBeforeUnload,
    FutureOr<PermissionResponse?> Function(dynamic, PermissionRequest)?
    onPermissionRequest,
    FutureOr<HttpAuthResponse?> Function(dynamic, HttpAuthenticationChallenge)?
    onReceivedHttpAuthRequest,
    FutureOr<ServerTrustAuthResponse?> Function(dynamic, ServerTrustChallenge)?
    onReceivedServerTrustAuthRequest,
    FutureOr<bool?> Function(dynamic, CreateWindowAction)? onCreateWindow,
    FutureOr<CustomSchemeResponse?> Function(dynamic, WebResourceRequest)?
    onLoadResourceWithCustomScheme,
    FutureOr<DownloadStartResponse?> Function(dynamic, DownloadStartRequest)?
    onDownloadStarting,
    void Function(dynamic, WebResourceRequest, WebResourceError)?
    onReceivedError,
    void Function(dynamic, WebUri?)? onLoadStart,
    ContextMenu? contextMenu,
  }) async {
    late TestView t;
    final view = LinuxHeadlessInAppWebView(
      LinuxHeadlessInAppWebViewCreationParams(
        initialData: url == null
            ? InAppWebViewInitialData(
                data: html ?? plainPage,
                baseUrl: WebUri(baseUrl),
              )
            : null,
        initialUrlRequest: url == null ? null : URLRequest(url: WebUri(url)),
        initialSettings: settings,
        initialSize: const Size(400, 300),
        windowId: windowId,
        contextMenu: contextMenu,
        onWebViewCreated: (c) {
          t._controller = c as LinuxInAppWebViewController;
          onCreated?.call(t._controller!);
        },
        onLoadStart: onLoadStart,
        onLoadStop: (_, u) => t.loadStops.add(u?.toString()),
        onConsoleMessage: (_, m) => t.console.add(m.message),
        onReceivedError: (c, r, e) {
          t.errors.add(e);
          onReceivedError?.call(c, r, e);
        },
        shouldOverrideUrlLoading: shouldOverrideUrlLoading,
        onNavigationResponse: onNavigationResponse,
        onJsAlert: onJsAlert,
        onJsConfirm: onJsConfirm,
        onJsPrompt: onJsPrompt,
        onJsBeforeUnload: onJsBeforeUnload,
        onPermissionRequest: onPermissionRequest,
        onReceivedHttpAuthRequest: onReceivedHttpAuthRequest,
        onReceivedServerTrustAuthRequest: onReceivedServerTrustAuthRequest,
        onCreateWindow: onCreateWindow,
        onLoadResourceWithCustomScheme: onLoadResourceWithCustomScheme,
        onDownloadStarting: onDownloadStarting,
      ),
    );
    t = TestView._(view);
    await view.run();
    if (waitForLoad) {
      await waitFor(tester, () => t.loadStops.isNotEmpty, reason: 'first load');
    }
    return t;
  }

  Future<dynamic> js(String source) =>
      controller.evaluateJavascript(source: source);

  /// Runs [body] as an async function and returns its value.
  Future<dynamic> asyncJs(String body) async =>
      (await controller.callAsyncJavaScript(functionBody: body))?.value;

  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await view.dispose();
  }
}

/// Test-only native hooks (example/linux/runner/review_test_hooks.cc).
/// Requires FLUTTER_INAPPWEBVIEW_REVIEW_HOOKS=1 in the app's environment.
class Hooks {
  static const _channel = MethodChannel(
    'flutter_inappwebview_example/review_hooks',
  );

  static Future<bool> available() async {
    try {
      await _channel.invokeMethod<List<Object?>>('listDialogs');
      return true;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<List<String>> dialogs() async =>
      ((await _channel.invokeMethod<List<Object?>>('listDialogs')) ?? const [])
          .cast<String>();

  static Future<bool> respond(
    String kind, {
    bool ok = true,
    String? color,
    String? path,
  }) async =>
      (await _channel.invokeMethod<bool>('respondDialog', {
        'kind': kind,
        'response': ok ? 'ok' : 'cancel',
        'color': ?color,
        'path': ?path,
      })) ??
      false;

  static Future<bool> setCalendarDate(int year, int month, int day) async =>
      (await _channel.invokeMethod<bool>('setCalendarDate', {
        'year': year,
        'month': month,
        'day': day,
      })) ??
      false;

  static Future<bool> popupVisible() async =>
      (await _channel.invokeMethod<bool>('popupVisible')) ?? false;

  /// [rows]: one letter per popup row, top to bottom: i = item, s = separator.
  static Future<bool> clickPopupItem(int index, String rows) async =>
      (await _channel.invokeMethod<bool>('clickPopupItem', {
        'index': index,
        'rows': rows,
      })) ??
      false;

  /// Live instances of a WebKit type counted by the runner hooks
  /// (WebKitWebView, WebKitNetworkSession, WebKitDownload,
  /// WebKitUserContentManager). Fails the test if the type is not counted.
  /// With [created], returns instances ever constructed instead.
  static Future<int> instanceCount(String type, {bool created = false}) async {
    final n =
        (await _channel.invokeMethod<int>('instanceCount', {
          'type': type,
          'created': created,
        })) ??
        -1;
    if (n < 0) fail('instance counter does not track $type');
    return n;
  }
}

/// Creates and disposes one view so WebKit's GObject types are registered
/// and the shared session exists before a test takes an instance-count
/// baseline.
Future<void> warmUpWebKit(WidgetTester tester) async {
  final t = await TestView.start(tester);
  await t.dispose();
  await settle(tester, const Duration(seconds: 1));
}

/// Skips the rest of a test when the native hooks are not compiled in or
/// not enabled. Returns true when the test should stop.
Future<bool> skipWithoutHooks() async {
  if (await Hooks.available()) return false;
  markTestSkipped(
    'needs FLUTTER_INAPPWEBVIEW_REVIEW_HOOKS=1 (example runner hooks)',
  );
  return true;
}

/// Self-signed certificate for 127.0.0.1, test use only.
const testCertPem = """-----BEGIN CERTIFICATE-----
MIIC+TCCAeGgAwIBAgIUfhqVcEqlGZ/GVn0FOWrnzBjCb5owDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MTAxOTA3NTgzMFoXDTM2MTAx
NjA3NTgzMFowFDESMBAGA1UEAwwJMTI3LjAuMC4xMIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAwN0Oc+Jh9TbvIZCbPlmr3JAEaecLnmm/ZYkITlLjI0jy
Z88jrOhZDeHe+4iLA5/9xM48pzERt3lfwmnx4xzMVyfzP4WGhNhO+xEJhIp/MCxB
psv65IXM+e5F/8Qe0bgRtfHjUTAKZkpQSFvjOIy7sqf0yfdwQoSMWCMfAMt6wrTM
6Xto7muyHtHZcr0m+WFqJYEFvkv2byG4Alpe5XH1Cmm1vHRsCUH9HlNTCMmWv80t
XbkVetBFF5UqXJTLrAYzSNrPB4T3iaxvbYDhmU7VdiBgTky4ZcL+PQjLs/UBZKWZ
P64Gkt8D1OX58+PNIQcg7Uc3vIKK/LuFSO7ld9yDRQIDAQABo0MwQTAdBgNVHQ4E
FgQUqQ2lVZl/HiC0rRMn0Cei/ojDOT8wDwYDVR0TAQH/BAUwAwEB/zAPBgNVHREE
CDAGhwR/AAABMA0GCSqGSIb3DQEBCwUAA4IBAQAyMN/baUljEbpkBLVmIM0SQFzd
CER8z8aHE1+at7vEmf+2cypq+P7rDBnvfydyW5cPlzE+K+gBqkDAXs5sVFCDd+EP
Sw2Ga176kwwgaeoviyQeUBrfaVpH2sDJ0qGSKwogTXHzLhT+QbKIniHKJlHSYh4y
5OfYwak7a0b/dKnCTcUxGzArZEzYurt7zsdzrej0ljnRbklGxafs+onGKKbyr3zM
YvBHESVlnu/1pXA4hElJoplMB4Z1/yJhu6ojovJ5khmMxEN3FvkDWw9SenTCMBdR
2DKRp8EqxlniIBKFrUQnZ1aarXWFEX/vLfMl5WMeONEcTUm++iIdRKuQoeBK
-----END CERTIFICATE-----""";
const testKeyPem = """-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDA3Q5z4mH1Nu8h
kJs+WavckARp5wueab9liQhOUuMjSPJnzyOs6FkN4d77iIsDn/3EzjynMRG3eV/C
afHjHMxXJ/M/hYaE2E77EQmEin8wLEGmy/rkhcz57kX/xB7RuBG18eNRMApmSlBI
W+M4jLuyp/TJ93BChIxYIx8Ay3rCtMzpe2jua7Ie0dlyvSb5YWolgQW+S/ZvIbgC
Wl7lcfUKabW8dGwJQf0eU1MIyZa/zS1duRV60EUXlSpclMusBjNI2s8HhPeJrG9t
gOGZTtV2IGBOTLhlwv49CMuz9QFkpZk/rgaS3wPU5fnz480hByDtRze8gor8u4VI
7uV33INFAgMBAAECggEAAWXfMbaS7cvso5tpF1Nwd9VfzgQKi41OVwQaKUbo3KI/
BsLeTm5Otqy/FacxnbGtWi69cZuYz8c1nC6CvisNs/ywtgwgSfyvQvBItXoiUUa0
lFFLlm11c+2m2E4e+3eSdUq5p7eyU5nRB1sbatLiDc8X6sUeV+QFMu+MXkfwoPRS
c0GQvIdmWnqCmc8BjvcjsGVvHm+9RmFGWyTkmb7OGH/5KxnK3Dbp1ClqycmpIm5p
N+L68pjhSEPtEBjEAzfFb3Suq1dbtwAX7+F8h8FGOZm0eWayymCP6YrfAQ3tF/Dj
QOBPJyUpH8b42CQdIJHbGLxSOFAVtnfzNdPmyC8AzwKBgQDinf9DxyyK3PLgOn0y
NpqZaAOfB5qg2rc5j8FUIF9u+6vQo5aGpsymCPCrHS6ymU4f41qcSfKqjB2x1QGg
Cm7g/ZnkfIpWXBwMa35KjpTzezKHQCW8u8A2uIT4wVlSmMcGfvqGTs8nFWOWBCZM
TtiCyAhRKE7I3gLbsrmvUq1GMwKBgQDZ3rBMMP/XS3cZ0EpbWUJgQCUepDHXEb1S
qPchKvWLTOB0xDUPCeA38qw+eJflsxdbkTg11t7tFM/xztJA9oOWLpePL14VAw65
EU1wRaBd/zTMzP6x77w95UavwtgtMDl47ChNj6VM7btcBoE7+ahJJWXVeib9g9c/
fMhvtXVopwKBgCobMz/TtSoEDbiuBW8cCDOyyOF2lzuGB/9Q/5ny/ehwKKd2jdRt
D59WD+mrXW7f3007gC2D6+vWZvoQ2uFyrtFtLXfv0ABl0uxX2Lpfrbtjy6qnt5tO
w1Mni8Vwn3kiW/CQDVqBMCpR5hQMp1UMXVxHcIwr0h+uaJeLqMaztPBTAoGBAIfr
q+T8tL/mLrmF/r2apBRUMFQ7b3STdp95FiQ1Htb28Rknx0pIiP+ef+LBbVI6NppD
sOO114Hk+A4NT5KDuHgbPSZxEKrfK3I93yfp6DB8JL6YLVVpEPE0drL0RdV7Pn+4
JTSuJxwlPDwfOsTl7h0kHbHe8TA77i+Hc6xtcoAFAoGAXjS080iYNdd41Fpc61iT
R97kHqjnZ158pbgHYfjOgYMOIQgQdoQogNTUrbrAzcAWO3fQKQZfWi6+J3SdRjy0
Ey8F+gTfbriBHZ0jMXgWk3uVupLSsPESDvWs9YYNLC4zGv0pdI4hZPWS/IUHs7o3
tmqet5HDpUhGGnXBTXwz4LI=
-----END PRIVATE KEY-----""";

/// A local HTTP or HTTPS server. Handlers are set per path; every request is
/// recorded.
class LocalServer {
  LocalServer._(this._server, this.scheme);

  final HttpServer _server;
  final String scheme;
  final requests = <RecordedRequest>[];
  final handlers =
      <String, FutureOr<void> Function(HttpRequest r, List<int> body)>{};

  int get port => _server.port;
  String url(String path) => '$scheme://127.0.0.1:$port$path';

  static Future<LocalServer> start({bool https = false}) async {
    final HttpServer server;
    if (https) {
      final context = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(testCertPem))
        ..usePrivateKeyBytes(utf8.encode(testKeyPem));
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
    } else {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    final s = LocalServer._(server, https ? 'https' : 'http');
    server.listen((r) async {
      final body = await r.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      s.requests.add(
        RecordedRequest(
          r.method,
          r.uri.toString(),
          body,
          r.headers.contentType?.mimeType,
        ),
      );
      final h = s.handlers[r.uri.path];
      try {
        if (h != null) {
          await h(r, body);
        } else {
          r.response
            ..headers.contentType = ContentType.html
            ..write('<!doctype html><html><body>${r.uri.path}</body></html>');
        }
      } catch (_) {}
      try {
        await r.response.close();
      } catch (_) {}
    });
    return s;
  }

  Future<void> close() => _server.close(force: true);
}

class RecordedRequest {
  RecordedRequest(this.method, this.uri, this.body, this.contentType);
  final String method;
  final String uri;
  final List<int> body;
  final String? contentType;
  @override
  String toString() => '$method $uri (${body.length} bytes, $contentType)';
}
