// What a sign-out clear (WebsiteDataType.ALL from the epoch, as Telosnex
// does) leaves behind. The device ID hash salt lets websites link camera and
// microphone IDs across users of one device; WebKit removes it with cookies.
// Cache API storage (WebKit's DOM cache) is site data the old type mapping
// never cleared. Run: `flutter test integration_test/sign_out_clear_test.dart
// -d linux`.

import 'dart:io';

import 'package:flutter_inappwebview_linux/flutter_inappwebview_linux.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'review_common.dart';

/// Salt files of the default WebKit session, wherever WPE keeps its data.
List<String> saltFiles() {
  final home = Platform.environment['HOME']!;
  final roots = [
    Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share',
    Platform.environment['XDG_CACHE_HOME'] ?? '$home/.cache',
  ];
  final found = <String>[];
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final app in dir.listSync().whereType<Directory>()) {
      if (!app.path.contains('inappwebview')) continue;
      for (final e in app.listSync(recursive: true, followLinks: false)) {
        if (e is File && e.path.contains('deviceidhashsalts')) {
          found.add(e.path);
        }
      }
    }
  }
  return found;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> run(WidgetTester tester, Set<WebsiteDataType>? clear) async {
    final t = await TestView.start(tester, baseUrl: 'https://salt.example/');
    try {
      final devices = await t.asyncJs('''
        if (!navigator.mediaDevices) return 'no mediaDevices';
        const d = await navigator.mediaDevices.enumerateDevices();
        return d.length;
      ''');
      // ignore: avoid_print
      print('[SALT] enumerateDevices: $devices');
      await settle(tester, const Duration(seconds: 2));
      final before = saltFiles();
      // ignore: avoid_print
      print('[SALT] before: ${before.length}');
      expect(before, isNotEmpty, reason: 'no salt was written; test is void');
      if (clear != null) {
        await LinuxWebStorageManager(
          const LinuxWebStorageManagerCreationParams(),
        ).removeDataModifiedSince(
          dataTypes: clear,
          date: DateTime.fromMillisecondsSinceEpoch(0),
        );
      }
      await settle(tester, const Duration(seconds: 2));
      final after = saltFiles();
      // ignore: avoid_print
      print(
        '[SALT] after (${clear == null ? 'no clear' : '${clear.length} types'}): ${after.length}',
      );
      if (clear == null) {
        expect(after, isNotEmpty, reason: 'salt gone without clearing it');
      } else {
        expect(after, isEmpty);
      }
    } finally {
      await t.dispose();
    }
  }

  testWidgets('control: the salt stays without a clear', (tester) async {
    await run(tester, null);
  });

  testWidgets('WebKit removes the salt with cookies', (tester) async {
    await run(tester, {WebsiteDataType.WKWebsiteDataTypeCookies});
  });

  testWidgets('WebsiteDataType.ALL clears device ID hash salts', (
    tester,
  ) async {
    await run(tester, WebsiteDataType.ALL);
  });

  testWidgets('WebsiteDataType.ALL clears Cache API storage', (tester) async {
    Future<dynamic> cacheNames() async {
      final t = await TestView.start(tester, baseUrl: 'https://cache.example/');
      try {
        return await t.asyncJs('return (await caches.keys()).join(",");');
      } finally {
        await t.dispose();
      }
    }

    final t = await TestView.start(tester, baseUrl: 'https://cache.example/');
    try {
      await t.asyncJs('''
        const c = await caches.open('signed-in');
        await c.put('/secret', new Response('account data'));
        return 1;
      ''');
    } finally {
      await t.dispose();
    }
    final before = await cacheNames();
    // ignore: avoid_print
    print('[CACHE] before: $before');
    expect(before, 'signed-in', reason: 'Cache API not stored; test is void');

    await LinuxWebStorageManager(
      const LinuxWebStorageManagerCreationParams(),
    ).removeDataModifiedSince(
      dataTypes: WebsiteDataType.ALL,
      date: DateTime.fromMillisecondsSinceEpoch(0),
    );
    await settle(tester, const Duration(seconds: 1));
    final after = await cacheNames();
    // ignore: avoid_print
    print('[CACHE] after: $after');
    expect(after, '');
  });
}
