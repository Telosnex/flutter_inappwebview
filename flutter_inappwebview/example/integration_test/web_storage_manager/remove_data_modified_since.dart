part of 'main.dart';

const _seedJs = '''
(async () => {
  localStorage.setItem('wsm_key', 'wsm_value');
  await new Promise((resolve, reject) => {
    const request = indexedDB.open('wsm_db', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('s');
    request.onsuccess = () => { request.result.close(); resolve(); };
    request.onerror = () => reject(request.error);
  });
  return true;
})()
''';

const _readJs = '''
(async () => {
  const names = indexedDB.databases
    ? (await indexedDB.databases()).map((d) => d.name)
    : [];
  return {
    local: localStorage.getItem('wsm_key'),
    indexedDb: names.includes('wsm_db'),
  };
})()
''';

/// Loads [TEST_CROSS_PLATFORM_URL_1] in a fresh WebView, runs [js] and
/// removes the WebView again, so the clear runs with no WebView open.
Future<dynamic> _runInPage(WidgetTester tester, String js) async {
  final controller = Completer<InAppWebViewController>();
  final loaded = Completer<void>();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: InAppWebView(
        key: GlobalKey(),
        initialUrlRequest: URLRequest(url: TEST_CROSS_PLATFORM_URL_1),
        onWebViewCreated: controller.complete,
        onLoadStop: (_, __) {
          if (!loaded.isCompleted) loaded.complete();
        },
      ),
    ),
  );
  await loaded.future;
  final result = await (await controller.future).callAsyncJavaScript(
    functionBody: 'return await $js;',
  );
  await tester.pumpWidget(Container());
  await tester.pump(const Duration(milliseconds: 500));
  return result?.value;
}

void removeDataModifiedSince() {
  skippableTestWidgets('ALL since the epoch clears storage with no WebView '
      'open', (WidgetTester tester) async {
    final cookieUrl = WebUri(TEST_CROSS_PLATFORM_URL_1.toString());
    expect(await _runInPage(tester, _seedJs), isTrue);
    await CookieManager.instance().setCookie(
      url: cookieUrl,
      name: 'wsm_cookie',
      value: 'v',
    );
    final seeded = await _runInPage(tester, _readJs);
    expect(seeded['local'], 'wsm_value');
    expect(seeded['indexedDb'], isTrue);

    await WebStorageManager.instance().removeDataModifiedSince(
      dataTypes: WebsiteDataType.ALL,
      date: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final cleared = await _runInPage(tester, _readJs);
    expect(cleared['local'], isNull);
    expect(cleared['indexedDb'], isFalse);
    expect(
      await CookieManager.instance().getCookie(
        url: cookieUrl,
        name: 'wsm_cookie',
      ),
      isNull,
    );
  });

  // Windows and Linux (WPE: the date becomes a span back from now).
  skippableTestWidgets('date: keeps data older than it, removes newer', (
    WidgetTester tester,
  ) async {
    expect(await _runInPage(tester, _seedJs), isTrue);

    // Data written before the date is kept.
    await WebStorageManager.instance().removeDataModifiedSince(
      dataTypes: {WebsiteDataType.WKWebsiteDataTypeLocalStorage},
      date: DateTime.now().add(const Duration(hours: 1)),
    );
    expect((await _runInPage(tester, _readJs))['local'], 'wsm_value');

    // Data written after the date is removed. A date sent in the wrong unit
    // (ms read as s) lands in the far future and removes nothing.
    await WebStorageManager.instance().removeDataModifiedSince(
      dataTypes: {WebsiteDataType.WKWebsiteDataTypeLocalStorage},
      date: DateTime.now().subtract(const Duration(hours: 1)),
    );
    final after = await _runInPage(tester, _readJs);
    expect(after['local'], isNull);
    // Only local storage was requested.
    expect(after['indexedDb'], isTrue);
  }, skip: defaultTargetPlatform != TargetPlatform.windows &&
      defaultTargetPlatform != TargetPlatform.linux);
}
