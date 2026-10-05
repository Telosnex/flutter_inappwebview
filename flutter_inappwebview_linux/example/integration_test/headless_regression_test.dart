import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_linux/flutter_inappwebview_linux.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LinuxInAppWebViewPlatform.registerWith();
  });

  testWidgets('initial scripts run before content and report JS completion', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final completion = Completer<List<dynamic>>();
    final view = LinuxHeadlessInAppWebView(
      LinuxHeadlessInAppWebViewCreationParams(
        initialData: InAppWebViewInitialData(
          data: '''<!doctype html><html><head><script>
window.pageSawStart = window.startMarker;
</script></head><body>Offline regression fixture</body></html>''',
        ),
        initialUserScripts: UnmodifiableListView([
          UserScript(
            source: 'window.startMarker = "installed-before-page";',
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
          UserScript(
            source: '''
(() => {
  const result = [window.startMarker, window.pageSawStart,
    document.body.textContent];
  window.flutter_inappwebview.callHandler('regressionComplete', ...result);
})();''',
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
          ),
        ]),
        onWebViewCreated: (controller) {
          controller.addJavaScriptHandler(
            handlerName: 'regressionComplete',
            callback: (JavaScriptHandlerFunctionData data) {
              if (!completion.isCompleted) completion.complete(data.args);
              return null;
            },
          );
        },
      ),
    );
    try {
      await view.run();
      expect(await completion.future.timeout(const Duration(seconds: 20)), [
        'installed-before-page',
        'installed-before-page',
        'Offline regression fixture',
      ]);
    } finally {
      await view.dispose();
    }
  });

  testWidgets('immediate dispose removes each native headless view', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    var created = 0;
    for (var i = 0; i < 10; i++) {
      final view = LinuxHeadlessInAppWebView(
        LinuxHeadlessInAppWebViewCreationParams(
          initialData: InAppWebViewInitialData(
            data: '<html><body>close</body></html>',
          ),
          onWebViewCreated: (_) => created++,
        ),
      );
      final channel = MethodChannel(
        'com.pichillilorenzo/flutter_headless_inappwebview_${view.id}',
      );
      const codec = StandardMethodCodec();
      var nativeDisposeAcknowledged = false;
      final messenger = binding.defaultBinaryMessenger;
      // Observe the reply, but forward every message to the real native plugin.
      // A missing native dispose is the startup race, even if Dart flags reset.
      messenger.setMockMethodCallHandler(channel, (call) async {
        final response = await messenger.delegate.send(
          channel.name,
          codec.encodeMethodCall(call),
        );
        final result = codec.decodeEnvelope(response!);
        if (call.method == 'dispose') {
          expect(result, isTrue);
          nativeDisposeAcknowledged = true;
        }
        return result;
      });
      try {
        final run = view.run();
        final dispose = view.dispose();
        await run;
        await dispose;
        expect(nativeDisposeAcknowledged, isTrue);
        expect(view.isRunning(), isFalse);
        expect(view.webViewController, isNull);
      } finally {
        await view.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    }
    await tester.pump();
    expect(created, 0);
  });
}
