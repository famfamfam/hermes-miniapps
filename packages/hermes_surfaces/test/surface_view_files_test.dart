// A published page moves files only through the bridge: the picker and the sheet are the application's, the bytes
// travel host <-> server, and the page can show a stored picture of its own app with a plain <img>.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'locale_support.dart';

class _WebViewPlatform extends InAppWebViewPlatform {
  final List<_WebView> pages = [];
  final Map<Key?, _Controller> controllers = {};

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(PlatformInAppWebViewWidgetCreationParams params) {
    final page = _WebView(params, controllers.putIfAbsent(params.key, _Controller.new));
    pages.add(page);
    return page;
  }

  @override
  PlatformWebViewFeature createPlatformWebViewFeatureStatic() => _Feature();
  @override
  PlatformWebMessageListener createPlatformWebMessageListener(PlatformWebMessageListenerCreationParams params) =>
      _Listener(params);
}

class _Feature extends PlatformWebViewFeature {
  _Feature() : super.implementation(const PlatformWebViewFeatureCreationParams());
  @override
  Future<bool> isFeatureSupported(WebViewFeature feature) async => true;
}

class _Listener extends PlatformWebMessageListener {
  _Listener(super.params) : super.implementation();
  @override
  void dispose() {}
}

class _Reply extends PlatformJavaScriptReplyProxy {
  _Reply(PlatformWebMessageListener listener)
      : super.implementation(PlatformJavaScriptReplyProxyCreationParams(webMessageListener: listener));
  final List<Map<String, dynamic>> messages = [];
  @override
  Future<void> postMessage(WebMessage message) async {
    messages.add(jsonDecode(message.data as String) as Map<String, dynamic>);
  }
}

class _Controller extends PlatformInAppWebViewController {
  _Controller() : super.implementation(const PlatformInAppWebViewControllerCreationParams(id: 0));
  PlatformWebMessageListener? listener;
  final scripts = <String>[];
  @override
  Future<void> addWebMessageListener(PlatformWebMessageListener webMessageListener) async => listener = webMessageListener;
  @override
  Future<void> loadUrl({required URLRequest urlRequest, WebUri? allowingReadAccessTo, Uri? iosAllowingReadAccessTo}) async {}
  @override
  Future<bool> canGoBack() async => false;
  @override
  Future<dynamic> evaluateJavascript({required String source, ContentWorld? contentWorld}) async {
    scripts.add(source);
    return null;
  }
}

class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params, this.native) : super.implementation();
  final _Controller native;
  late final controller = InAppWebViewController.fromPlatform(platform: native);

  Future<WebResourceResponse?> intercept(String url, {bool main = false, String method = 'GET'}) =>
      params.shouldInterceptRequest!(controller, WebResourceRequest(url: WebUri(url), method: method, isForMainFrame: main));

  Future<void> deliver(String url) async {
    params.onLoadStart?.call(controller, WebUri(url));
    await intercept(url, main: true);
    params.onLoadStop?.call(controller, WebUri(url));
  }

  _Reply send(String origin, int id, Map<String, Object?> rpc, {bool main = true}) {
    final listener = native.listener!;
    final reply = _Reply(listener);
    listener.onPostMessage!(WebMessage(data: jsonEncode({'id': id, 'rpc': rpc})), WebUri(origin), main, reply);
    return reply;
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller) as T;
  @override
  void dispose() {}
}

class _Bundles extends BundleStore {
  _Bundles(this.app) : super(app.dir);
  final InstalledApp app;
  @override
  Future<InstalledApp?> current(String appId) async => app;
  @override
  Future<Uint8List?> read(InstalledApp app, String path) async =>
      app.files.contains(path) ? Uint8List.fromList(utf8.encode('<html>page</html>')) : null;
}

class _Actions extends HostFileActions {
  int picks = 0;
  PickedFile? toPick;
  @override
  Future<PickedFile?> pick(BuildContext context, {required List<String> accept}) async {
    picks++;
    return toPick;
  }

  @override
  Future<FileOfferResult> offer(BuildContext context,
          {required String name, required String mime, required Uint8List bytes}) async =>
      FileOfferResult.saved;
}

const fileId = 'f_0123456789abcdef';
const pictureId = 'f_fedcba9876543210';
final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 9, 9]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final published = ServerConfig(baseUri: Uri.parse('http://localhost:8787'), token: 'test', deviceId: 'test');
  late _WebViewPlatform platform;
  late List<http.Request> requests;
  late List<Map<String, dynamic>> events;
  late _Actions actions;

  InstalledApp makeApp({bool preview = false}) => InstalledApp(
        appId: 'utilities',
        title: 'Test app',
        bundleId: 'sha256:${'a' * 64}',
        revision: 5,
        contractHash: 'contract',
        epoch: 'e1',
        dir: Directory.systemTemp,
        files: {'index.html'},
        entrypoint: 'index.html',
        installedAt: DateTime.utc(2026, 10, 17),
        preview: preview ? const PreviewIdentity(buildId: 'build_aaaaaaaaaa', baseRevision: 0) : null,
      );

  http.Response answer(http.Request r) {
    requests.add(r);
    final path = r.url.path;
    if (path.endsWith('/events')) {
      return http.Response(jsonEncode({'epoch': 'e1', 'seq': 10, 'reset': false, 'events': events}), 200);
    }
    if (r.method == 'POST' && path.endsWith('/apps/utilities/files')) {
      return http.Response(
          jsonEncode({
            'fileId': fileId,
            'name': 'a.pdf',
            'mime': 'application/pdf',
            'size': r.bodyBytes.length,
            'source': 'phone',
            'createdAt': 'now',
            'duplicate': false,
          }),
          200);
    }
    if (path.endsWith('/files/$pictureId')) {
      return http.Response.bytes(png, 200, headers: {'content-type': 'image/png', 'x-file-name': 'p.png'});
    }
    if (path.endsWith('/files/$fileId')) {
      return http.Response.bytes([1, 2, 3], 200, headers: {'content-type': 'application/pdf', 'x-file-name': 'a.pdf'});
    }
    return http.Response('{"error":"unexpected"}', 404);
  }

  SurfacesHost makeHost({bool preview = false}) => SurfacesHost(
        api: preview
            ? PreviewApi(published.forPreview(), client: MockClient((r) async => answer(r)))
            : SurfacesApi(published, client: MockClient((r) async => answer(r))),
        bundles: _Bundles(makeApp(preview: preview)),
        snapshots: SnapshotCache(Directory.systemTemp),
      );

  setUp(() {
    platform = _WebViewPlatform();
    InAppWebViewPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_timezone'),
      (_) async => 'UTC',
    );
    requests = [];
    events = [];
    actions = _Actions();
  });

  Future<(_WebView, String)> open(WidgetTester tester, {bool preview = false, bool withActions = true}) async {
    final config = preview ? published.forPreview() : published;
    final app = makeApp(preview: preview);
    await tester.pumpWidget(localizedApp(
      locale: const Locale('en'),
      home: SurfaceView(
        host: makeHost(preview: preview),
        config: config,
        app: app,
        title: app.title,
        sealNetwork: false,
        fileActions: withActions ? actions : null,
        sendToHermes: withActions ? (_) async => true : null,
        preview: preview ? PreviewActions(approve: (_) async => null, reject: (_) async {}) : null,
      ),
    ));
    await tester.pump();
    final page = platform.pages.last;
    page.params.onWebViewCreated?.call(page.controller);
    await tester.pump();
    await tester.pump();
    final origin = AppOrigin.forApp(config.scope, app.appId).origin;
    await page.deliver('$origin/${app.entrypoint}');
    await tester.pump();
    return (page, origin);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('pickFile: the application\'s picker runs, the file is uploaded and the page gets the record', (tester) async {
    final (page, origin) = await open(tester);
    final bytes = Uint8List.fromList(List.generate(50, (i) => i));
    actions.toPick = PickedFile(name: 'a.pdf', length: 50, open: () => Stream.value(bytes));
    final reply = page.send(origin, 7, {'op': 'pickFile', 'accept': ['application/pdf']});
    await settle(tester);
    expect(actions.picks, 1);
    expect(reply.messages, hasLength(1));
    expect(reply.messages.single['id'], 7);
    expect(reply.messages.single['ok'], isTrue);
    expect((reply.messages.single['value'] as Map)['fileId'], fileId);
    final upload = requests.singleWhere((r) => r.method == 'POST');
    expect(upload.bodyBytes, bytes);
    expect(upload.url.path, endsWith('/apps/utilities/files'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a page in a preview is refused with a stable code and nothing opens', (tester) async {
    final (page, origin) = await open(tester, preview: true);
    final reply = page.send(origin, 8, {'op': 'pickFile'});
    await settle(tester);
    expect(actions.picks, 0);
    expect(reply.messages.single['ok'], isFalse);
    expect((reply.messages.single['error'] as Map)['code'], 'preview_blocked');
    expect(requests.where((r) => r.method != 'GET'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without the application\'s pickers the page is told so', (tester) async {
    final (page, origin) = await open(tester, withActions: false);
    final reply = page.send(origin, 9, {'op': 'listFiles'});
    await settle(tester);
    expect((reply.messages.single['error'] as Map)['code'], 'unsupported');
    expect(requests.where((r) => r.url.path.contains('/files')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a file operation from another origin or a subframe is refused by the gate', (tester) async {
    final (page, origin) = await open(tester);
    final foreign = page.send('https://evil.example', 10, {'op': 'pickFile'});
    final frame = page.send(origin, 11, {'op': 'pickFile'}, main: false);
    await settle(tester);
    expect(actions.picks, 0);
    expect((foreign.messages.single['error'] as Map)['code'], 'forbidden_origin');
    expect((frame.messages.single['error'] as Map)['code'], 'forbidden_frame');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a stored picture is served on the page\'s own origin with the page\'s security headers', (tester) async {
    final (page, origin) = await open(tester);
    final res = await page.intercept('$origin/__hermes/files/$pictureId');
    expect(res!.statusCode, 200);
    expect(res.contentType, 'image/png');
    expect(res.data, png);
    expect(res.headers!['Content-Security-Policy'], contains("connect-src 'none'"));
    expect(res.headers!['X-Content-Type-Options'], 'nosniff');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('what is not a picture of this app is a 404, and what is not this origin stays blocked', (tester) async {
    final (page, origin) = await open(tester);
    expect((await page.intercept('$origin/__hermes/files/$fileId'))!.statusCode, 404, reason: 'a PDF is not shown inline');
    expect((await page.intercept('$origin/__hermes/files/nope'))!.statusCode, 404);
    expect((await page.intercept('$origin/__hermes/files/'))!.statusCode, 403, reason: 'an empty segment is not a path at all');
    expect((await page.intercept('https://evil.example/__hermes/files/$pictureId'))!.statusCode, 403);
    expect((await page.intercept('$origin/__hermes/files/$pictureId', method: 'POST'))!.statusCode, 405);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a preview shows no stored picture', (tester) async {
    final (page, origin) = await open(tester, preview: true);
    expect((await page.intercept('$origin/__hermes/files/$pictureId'))!.statusCode, 404);
    expect(requests.where((r) => r.url.path.contains('/files')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a files.changed event of this app tells the page; one of another app does not', (tester) async {
    final (page, _) = await open(tester);
    final controller = page.native;
    await tester.pump(const Duration(seconds: 2)); // the first poll finds the server and tells the page once
    await tester.pump();
    controller.scripts.clear();
    events = [
      {'seq': 11, 'type': 'files.changed', 'appId': 'other_app', 'payload': {'fileId': fileId, 'change': 'added'}},
    ];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(controller.scripts.where((s) => s.contains('hermes:files-changed')), isEmpty);
    events = [
      {'seq': 12, 'type': 'files.changed', 'appId': 'utilities', 'payload': {'fileId': fileId, 'change': 'added'}},
    ];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(controller.scripts.where((s) => s.contains('hermes:files-changed')), hasLength(1));
    expect(controller.scripts.where((s) => s.contains('hermes:data-changed')), isEmpty, reason: 'a different event');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a deleted file is not served from memory afterwards', (tester) async {
    final (page, origin) = await open(tester);
    expect((await page.intercept('$origin/__hermes/files/$pictureId'))!.statusCode, 200);
    await page.intercept('$origin/__hermes/files/$pictureId');
    expect(requests.where((r) => r.url.path.endsWith('/files/$pictureId')), hasLength(1));
    events = [
      {'seq': 13, 'type': 'files.changed', 'appId': 'utilities', 'payload': {'fileId': pictureId, 'change': 'deleted'}},
    ];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await page.intercept('$origin/__hermes/files/$pictureId');
    expect(requests.where((r) => r.url.path.endsWith('/files/$pictureId')), hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });
}
