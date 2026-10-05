import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_linux/flutter_inappwebview_linux.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

const sharedChannel = MethodChannel(
  'com.pichillilorenzo/flutter_headless_inappwebview',
);
const codec = StandardMethodCodec();

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late LinuxHeadlessInAppWebView view;
  late List<String> calls;
  late Set<String> liveViews;
  late Completer<void> runReply;
  late Completer<void> runReceived;
  late int created;
  Object? disposeError;
  Completer<void>? disposeReply;

  Future<void> notifyCreated() async {
    final reply = Completer<void>();
    await messenger.handlePlatformMessage(
      'com.pichillilorenzo/flutter_headless_inappwebview_${view.id}',
      codec.encodeMethodCall(const MethodCall('onWebViewCreated', {})),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  setUp(() {
    LinuxInAppWebViewPlatform.registerWith();
    calls = [];
    liveViews = {};
    runReply = Completer<void>();
    runReceived = Completer<void>();
    created = 0;
    disposeError = null;
    disposeReply = null;
    view = LinuxHeadlessInAppWebView(
      LinuxHeadlessInAppWebViewCreationParams(
        onWebViewCreated: (_) => created++,
      ),
    );
    messenger.setMockMethodCallHandler(sharedChannel, (call) async {
      calls.add(call.method);
      runReceived.complete();
      await runReply.future;
      liveViews.add(view.id);
      return true;
    });
    messenger.setMockMethodCallHandler(
      MethodChannel(
        'com.pichillilorenzo/flutter_headless_inappwebview_${view.id}',
      ),
      (call) async {
        calls.add(call.method);
        if (disposeReply != null) await disposeReply!.future;
        if (disposeError != null) throw disposeError!;
        liveViews.remove(view.id);
        return true;
      },
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(sharedChannel, null);
    messenger.setMockMethodCallHandler(
      MethodChannel(
        'com.pichillilorenzo/flutter_headless_inappwebview_${view.id}',
      ),
      null,
    );
  });

  test('dispose waits for startup and removes the late-created view', () async {
    final run = view.run();
    await runReceived.future;
    final controller = view.webViewController!;
    final dispose = view.dispose();
    var disposed = false;
    final finished = dispose.then((_) => disposed = true);
    await notifyCreated();
    expect(created, 0);
    expect(disposed, isFalse);
    expect(calls, ['run']);

    runReply.complete();
    await run;
    await finished;
    expect(calls, ['run', 'dispose']);
    expect(liveViews, isEmpty);
    expect(view.isRunning(), isFalse);
    expect(view.webViewController, isNull);
    expect(controller.disposed, isTrue);
    await notifyCreated();
    expect(created, 0);
  });

  test('concurrent run callers wait for the same startup', () async {
    final first = view.run();
    final second = view.run();
    expect(second, same(first));
    await runReceived.future;
    expect(calls, ['run']);
    runReply.complete();
    await Future.wait([first, second]);
    await notifyCreated();
    expect(created, 1);
    expect(view.isRunning(), isTrue);
    await view.dispose();
  });

  test('concurrent disposals send one native dispose', () async {
    final run = view.run();
    await runReceived.future;
    final first = view.dispose();
    final second = view.dispose();
    expect(second, same(first));
    runReply.complete();
    await run;
    await Future.wait([first, second]);
    expect(calls, ['run', 'dispose']);
    await view.dispose();
    expect(calls, ['run', 'dispose']);
  });

  test('startup failure reaches run caller and disposal cleans up', () async {
    final run = view.run();
    final error = expectLater(run, throwsA(isA<PlatformException>()));
    await runReceived.future;
    final controller = view.webViewController!;
    final dispose = view.dispose();
    runReply.completeError(PlatformException(code: 'CREATE_FAILED'));
    await error;
    await dispose;
    expect(calls, ['run']);
    expect(liveViews, isEmpty);
    expect(view.isRunning(), isFalse);
    expect(view.webViewController, isNull);
    expect(controller.disposed, isTrue);
    await notifyCreated();
    expect(created, 0);
  });

  test('can retry after startup failure', () async {
    final run = view.run();
    final error = expectLater(run, throwsA(isA<PlatformException>()));
    await runReceived.future;
    runReply.completeError(PlatformException(code: 'CREATE_FAILED'));
    await error;
    runReceived = Completer<void>();
    runReply = Completer<void>()..complete();
    await view.run();
    expect(calls, ['run', 'run']);
    expect(view.isRunning(), isTrue);
    await view.dispose();
    expect(liveViews, isEmpty);
  });

  test('can retry a failed native disposal', () async {
    runReply.complete();
    await view.run();
    disposeError = PlatformException(code: 'DISPOSE_FAILED');
    await expectLater(view.dispose(), throwsA(isA<PlatformException>()));
    expect(view.isRunning(), isTrue);
    expect(liveViews, {view.id});
    disposeError = null;
    await view.dispose();
    expect(calls, ['run', 'dispose', 'dispose']);
    expect(view.isRunning(), isFalse);
    expect(liveViews, isEmpty);
  });

  test('does not restart while disposal is pending', () async {
    runReply.complete();
    await view.run();
    disposeReply = Completer<void>();
    final dispose = view.dispose();
    await view.run();
    expect(calls.where((call) => call == 'run'), hasLength(1));
    disposeReply!.complete();
    await dispose;
    expect(liveViews, isEmpty);
  });

  test('can restart after disposal', () async {
    runReply.complete();
    await view.run();
    await view.dispose();
    runReceived = Completer<void>();
    await view.run();
    expect(calls, ['run', 'dispose', 'run']);
    expect(view.isRunning(), isTrue);
    await view.dispose();
    expect(liveViews, isEmpty);
  });

  test('dispose before run is a no-op', () async {
    await view.dispose();
    expect(calls, isEmpty);
  });

  test('forwards both document-start and document-end scripts', () async {
    final scripts = [
      UserScript(
        source: 'start()',
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      UserScript(
        source: 'end()',
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
      ),
    ];
    final scriptedView = LinuxHeadlessInAppWebView(
      LinuxHeadlessInAppWebViewCreationParams(
        initialUserScripts: UnmodifiableListView(scripts),
      ),
    );
    Map<dynamic, dynamic>? sent;
    messenger.setMockMethodCallHandler(sharedChannel, (call) async {
      sent = (call.arguments as Map)['params'] as Map;
      return true;
    });
    final instanceChannel = MethodChannel(
      'com.pichillilorenzo/flutter_headless_inappwebview_${scriptedView.id}',
    );
    messenger.setMockMethodCallHandler(instanceChannel, (_) async => true);
    try {
      await scriptedView.run();
      expect(
        sent!['initialUserScripts'],
        scripts.map((s) => s.toMap()).toList(),
      );
    } finally {
      await scriptedView.dispose();
      messenger.setMockMethodCallHandler(instanceChannel, null);
    }
  });
}
