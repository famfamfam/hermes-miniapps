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

  /// Features the fake WebView reports as missing (everything else is supported).
  final Set<WebViewFeature> unsupported = {};

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(PlatformInAppWebViewWidgetCreationParams params) {
    final page = _WebView(params, controllers.putIfAbsent(params.key, _Controller.new));
    pages.add(page);
    return page;
  }
  @override
  PlatformWebViewFeature createPlatformWebViewFeatureStatic() => _Feature(unsupported);
  @override
  PlatformWebMessageListener createPlatformWebMessageListener(PlatformWebMessageListenerCreationParams params) =>
      _Listener(params);
}

class _Feature extends PlatformWebViewFeature {
  _Feature(this.unsupported) : super.implementation(const PlatformWebViewFeatureCreationParams());
  final Set<WebViewFeature> unsupported;
  @override
  Future<bool> isFeatureSupported(WebViewFeature feature) async => !unsupported.contains(feature);
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
  Future<bool>? back;
  int backCalls = 0;
  @override
  Future<void> addWebMessageListener(PlatformWebMessageListener webMessageListener) async => listener = webMessageListener;
  @override
  Future<void> loadUrl({required URLRequest urlRequest, WebUri? allowingReadAccessTo, Uri? iosAllowingReadAccessTo}) async {}
  @override
  Future<bool> canGoBack() async => await (back ?? Future.value(false));
  @override
  Future<void> goBack() async => backCalls++;
  @override
  Future<dynamic> evaluateJavascript({required String source, ContentWorld? contentWorld}) async => null;
}

class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params, this.native) : super.implementation();
  final _Controller native;
  late final controller = InAppWebViewController.fromPlatform(platform: native);

  void started(String url) => params.onLoadStart?.call(controller, WebUri(url));
  void loaded(String url) => params.onLoadStop?.call(controller, WebUri(url));
  Future<WebResourceResponse?> intercept(String url, {bool main = true, String method = 'GET'}) =>
      params.shouldInterceptRequest!(controller, WebResourceRequest(url: WebUri(url), method: method, isForMainFrame: main));
  Future<void> deliver(String url, {bool interceptFirst = false}) async {
    if (interceptFirst) {
      await intercept(url);
      started(url);
    } else {
      started(url);
      await intercept(url);
    }
    loaded(url);
  }
  _Reply query(String origin, int id) {
    final listener = native.listener!;
    final reply = _Reply(listener);
    listener.onPostMessage!(WebMessage(data: jsonEncode({
      'id': id, 'rpc': {'op': 'query', 'calls': [{'name': 'list'}]},
    })), WebUri(origin), true, reply);
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
  int readStatus = 200;
  bool missing = false;
  @override
  Future<InstalledApp?> current(String appId) async => app;
  @override
  Future<Uint8List?> read(InstalledApp app, String path) async {
    if (readStatus == 403) throw const FileSystemException('synthetic read failure');
    return missing || !app.files.contains(path) ? null : Uint8List.fromList(utf8.encode('<html>synthetic reviewed page</html>'));
  }
}

class _UpdatingHost extends SurfacesHost {
  _UpdatingHost(SurfacesHost original) : super(api: original.api, bundles: original.bundles, snapshots: original.snapshots);
  InstalledApp? next;
  Future<InstalledApp?>? delayed;
  int updates = 0;
  final List<Completer<QueryOutcome>> queries = [];

  @override
  Future<QueryOutcome> query(InstalledApp app, List<Map<String, dynamic>> calls, {required String timezone}) {
    final pending = Completer<QueryOutcome>();
    queries.add(pending);
    return pending.future;
  }

  @override
  Future<InstalledApp?> checkForUpdate(String appId, {InstalledApp? displayed}) async {
    updates++;
    if (delayed != null) {
      final update = delayed!;
      delayed = null;
      return update;
    }
    final update = next;
    next = null;
    return update;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final config = ServerConfig(baseUri: Uri.parse('http://localhost:8787'), token: 'test', deviceId: 'test').forPreview();
  final app = InstalledApp(
    appId: 'utilities', title: 'Test app', bundleId: 'sha256:${'a' * 64}', revision: 5,
    contractHash: 'contract', epoch: 'e1', dir: Directory.systemTemp, files: {'index.html', 'details.html'},
    entrypoint: 'index.html', installedAt: DateTime.utc(2026, 10, 13),
    preview: const PreviewIdentity(buildId: 'build_aaaaaaaaaa', baseRevision: 0),
  );
  final document = '${AppOrigin.forApp(config.scope, app.appId).origin}/${app.entrypoint}';
  late SurfacesHost host;
  late _WebViewPlatform platform;
  late bool gone;
  late int approvals;
  InstalledApp? approved;
  Future<String?>? decision;
  late int rejections;
  InstalledApp? rejected;
  Future<void>? rejection;
  late List<Map<String, dynamic>> events;
  late bool reset;

  setUp(() {
    platform = _WebViewPlatform();
    InAppWebViewPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_timezone'), (_) async => 'UTC',
    );
    gone = false;
    approvals = 0;
    approved = null;
    decision = null;
    rejections = 0;
    rejected = null;
    rejection = null;
    events = [];
    reset = true;
    host = SurfacesHost(
      api: PreviewApi(config, client: MockClient((r) async {
        if (r.url.path.endsWith('/events')) {
          return http.Response(jsonEncode({'epoch': 'e1', 'seq': 10, 'reset': reset, 'events': events}), 200);
        }
        if (gone) return http.Response('{"error":"nothing is awaiting review for this app"}', 404);
        return http.Response(jsonEncode({
          'appId': app.appId, 'title': app.title, 'revision': app.revision, 'epoch': app.epoch,
          'bundle': {'bundleId': app.bundleId, 'size': 1, 'format': 1, 'sdkMajor': 1,
            'capabilities': [], 'contractHash': app.contractHash},
          'preview': app.preview!.toJson(),
        }), 200);
      })),
      bundles: _Bundles(app), snapshots: SnapshotCache(Directory.systemTemp),
    );
  });

  SurfaceView view({bool seal = false}) => SurfaceView(
    host: host, config: config, app: app, title: app.title, sealNetwork: seal,
    preview: PreviewActions(approve: (shown) async {
      approvals++;
      approved = shown;
      return decision == null ? null : await decision;
    }, reject: (shown) async {
      rejections++;
      rejected = shown;
      if (rejection != null) await rejection;
    }),
  );

  FilledButton publishButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.ancestor(of: find.text('Опубликовать'), matching: find.byType(FilledButton)).first);

  Future<void> connect(WidgetTester tester, _WebView page) async {
    page.params.onWebViewCreated?.call(page.controller);
    await tester.pump();
    await tester.pump();
    expect(page.native.listener, isNotNull);
  }

  Future<void> open(WidgetTester tester, {bool ready = true, bool seal = false}) async {
    await tester.pumpWidget(localizedApp(home: Builder(builder: (context) => TextButton(
      onPressed: () => Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => view(seal: seal))),
      child: const Text('Open preview'),
    ))));
    await tester.tap(find.text('Open preview'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await connect(tester, platform.pages.last);
    if (ready) {
      await platform.pages.last.deliver(document);
      await tester.pump();
    }
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Опубликовать')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  InstalledApp replacement({bool newBundle = false, bool baseOnly = false}) => InstalledApp(
    appId: app.appId, title: app.title, bundleId: newBundle ? 'sha256:${'b' * 64}' : app.bundleId,
    revision: newBundle ? 6 : app.revision, contractHash: app.contractHash, epoch: app.epoch,
    dir: app.dir, files: app.files, entrypoint: app.entrypoint, installedAt: app.installedAt,
    preview: PreviewIdentity(buildId: baseOnly ? app.preview!.buildId : 'build_bbbbbbbbbb', baseRevision: baseOnly ? 1 : 0),
  );

  for (final afterFirstPoll in [false, true]) {
    testWidgets('reset reconciles an ended preview (${afterFirstPoll ? 'later reset' : 'first poll'})', (tester) async {
      await tester.pumpWidget(localizedApp(home: view()));
      if (afterFirstPoll) {
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(find.text('Опубликовать'), findsOneWidget);
      }
      gone = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Опубликовать'), findsNothing);
      expect(find.text('Отклонить'), findsNothing);
      expect(find.text('К списку приложений'), findsOneWidget);
      expect(find.byType(InAppWebView), findsNothing);
      expect(approvals, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final language in ['en', 'de', 'zz']) {
    testWidgets('the review bar speaks English for `` (English is the source and the fallback)', (tester) async {
      await tester.pumpWidget(localizedApp(locale: Locale(language), home: view()));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Publish'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      expect(find.text('Preview · not published yet'), findsOneWidget);
      expect(find.text('Опубликовать'), findsNothing);
      gone = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Back to the list of apps'), findsOneWidget);
      expect(find.text('Preview finished'), findsWidgets);
      expect(approvals, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('old terminal events do not end a newer current review', (tester) async {
    reset = false;
    events = [
      {'appId': app.appId, 'type': 'review.changed', 'payload': {'status': 'published'}},
      {'appId': app.appId, 'type': 'review.changed', 'payload': {'status': 'awaiting_review'}},
    ];
    await tester.pumpWidget(localizedApp(home: view()));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Опубликовать'), findsOneWidget);
    expect(find.text('К списку приложений'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a build under review is compared with the server every six seconds, with no event at all', (
    tester,
  ) async {
    reset = false;
    events = [];
    final updating = _UpdatingHost(host);
    host = updating;
    await tester.pumpWidget(localizedApp(home: view()));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(updating.updates, 0, reason: 'nothing happened yet: no event, not time yet');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(updating.updates, 1);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(updating.updates, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the background re-check does not grey out Publish while it waits for the server', (tester) async {
    reset = false;
    events = [];
    final updating = _UpdatingHost(host);
    host = updating;
    await open(tester);
    expect(publishButton(tester).onPressed, isNotNull);
    final pending = Completer<InstalledApp?>();
    updating.delayed = pending.future;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(updating.updates, 1, reason: 'the quiet check is waiting for the server');
    expect(publishButton(tester).onPressed, isNotNull, reason: 'a tap on Publish must not be lost to a re-check');
    pending.complete(null);
    await tester.pump();
    expect(publishButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a new build found by the background re-check replaces the page and asks again', (tester) async {
    reset = false;
    events = [];
    final updating = _UpdatingHost(host);
    host = updating;
    await open(tester);
    updating.next = replacement(newBundle: true);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();
    expect(updating.updates, 1);
    expect(publishButton(tester).onPressed, isNull, reason: 'the new page is not delivered yet');
    expect(approvals, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('successful approval closes the preview route despite PopScope', (tester) async {
    await open(tester);
    await tester.tap(find.text('Опубликовать'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await confirm(tester);
    expect(approvals, 1);
    expect(approved, same(app));
    expect(find.byType(SurfaceView), findsNothing);
    expect(find.text('Open preview'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('loading and about:blank cannot enable approval', (tester) async {
    await open(tester, ready: false);
    expect(publishButton(tester).onPressed, isNull);
    platform.pages.last.loaded('about:blank');
    await tester.pump();
    expect(publishButton(tester).onPressed, isNull);
    await platform.pages.last.deliver(document);
    await tester.pump();
    expect(publishButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  // Review finding 15: a refused start must not keep a progress bar running behind the failure text.
  testWidgets('control: the progress bar shows while a page loads and goes when it is delivered', (tester) async {
    await open(tester, ready: false);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await platform.pages.last.deliver(document);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final missing in [WebViewFeature.DOCUMENT_START_SCRIPT, WebViewFeature.PROXY_OVERRIDE]) {
    testWidgets('a failed network seal (${missing.toNativeValue()}) shows the failure without a progress bar',
        (tester) async {
      platform.unsupported.add(missing);
      await open(tester, ready: false, seal: true);
      expect(find.textContaining('не удалось закрыть сеть WebView'), findsOneWidget);
      expect(find.byType(InAppWebView), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(publishButton(tester).onPressed, isNull, reason: 'a page that never started cannot be approved');
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a WebView without a verifiable bridge shows no progress bar either', (tester) async {
    platform.unsupported.add(WebViewFeature.WEB_MESSAGE_LISTENER);
    await tester.pumpWidget(localizedApp(home: view()));
    platform.pages.last.params.onWebViewCreated?.call(platform.pages.last.controller);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('не поддерживает проверяемый мост'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('old page callbacks cannot make the replacement ready', (tester) async {
    final updating = _UpdatingHost(host);
    host = updating;
    await open(tester);
    final oldPage = platform.pages.last;
    updating.next = replacement();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(publishButton(tester).onPressed, isNull);
    oldPage.loaded(document);
    await tester.pump();
    expect(publishButton(tester).onPressed, isNull);
    await platform.pages.last.deliver(document);
    await tester.pump();
    expect(publishButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('approval receives the refreshed installed target, not the opening target', (tester) async {
    final updating = _UpdatingHost(host);
    host = updating;
    await open(tester);
    final newer = replacement(newBundle: true);
    updating.next = newer;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await platform.pages.last.deliver(document);
    await tester.pump();
    await tester.tap(find.text('Опубликовать'));
    await tester.pump();
    await confirm(tester);
    expect(approvals, 1);
    expect(approved, same(newer));
    await tester.pumpWidget(const SizedBox());
  });

  for (final baseOnly in [false, true]) {
    testWidgets('a ${baseOnly ? 'base' : 'build'} change during confirmation needs a fresh decision', (tester) async {
      final updating = _UpdatingHost(host);
      host = updating;
      await open(tester);
      await tester.tap(find.text('Опубликовать'));
      await tester.pump();
      final newer = replacement(baseOnly: baseOnly);
      updating.next = newer;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await platform.pages.last.deliver(document);
      await tester.pump();
      await confirm(tester);
      expect(approvals, 0);
      expect(find.text('Сборка изменилась. Посмотрите новую версию и подтвердите её заново.'), findsOneWidget);
      await tester.tap(find.text('Опубликовать'));
      await tester.pump();
      await confirm(tester);
      expect(approvals, 1);
      expect(approved, same(newer));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('duplicate taps create one dialog and cancellation restores approval', (tester) async {
    await open(tester);
    final click = publishButton(tester).onPressed!;
    click();
    click();
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(approvals, 0);
    await tester.tap(find.text('Отмена'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(publishButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final status in [403, 404]) {
    testWidgets('a local $status main document cannot enable approval', (tester) async {
      final bundles = host.bundles as _Bundles;
      bundles.readStatus = status;
      bundles.missing = status == 404;
      await open(tester, ready: false);
      final page = platform.pages.last;
      page.started(document);
      expect((await page.intercept(document))!.statusCode, status);
      page.loaded(document);
      await tester.pump();
      expect(publishButton(tester).onPressed, isNull);
      expect(approvals, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a subframe delivery and a bare loadStop are not reviewed-document delivery', (tester) async {
    await open(tester, ready: false);
    final page = platform.pages.last;
    page.loaded(document);
    await tester.pump();
    expect(publishButton(tester).onPressed, isNull);
    page.started(document);
    expect((await page.intercept(document, main: false))!.statusCode, 200);
    page.loaded(document);
    await tester.pump();
    expect(publishButton(tester).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('interception before loadStart still proves the current document delivery', (tester) async {
    await open(tester, ready: false);
    await platform.pages.last.deliver(document, interceptFirst: true);
    await tester.pump();
    expect(publishButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('another bundled HTML document can be reviewed after internal navigation', (tester) async {
    await open(tester);
    final page = platform.pages.last;
    final details = document.replaceFirst('index.html', 'details.html');
    final action = NavigationAction(request: URLRequest(url: WebUri(details)), isForMainFrame: true);
    expect(await page.params.shouldOverrideUrlLoading!(page.controller, action), NavigationActionPolicy.ALLOW);
    await page.deliver(details);
    await tester.pump();
    expect(publishButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('same-controller reload during confirmation requires a new decision', (tester) async {
    await open(tester);
    await tester.tap(find.text('Опубликовать'));
    await tester.pump();
    await platform.pages.last.deliver(document);
    await tester.pump();
    await confirm(tester);
    expect(approvals, 0);
    expect(find.text('Сборка изменилась. Посмотрите новую версию и подтвердите её заново.'), findsOneWidget);
    await tester.tap(find.text('Опубликовать'));
    await tester.pump();
    await confirm(tester);
    expect(approvals, 1);
    await tester.pumpWidget(const SizedBox());
  });

  for (final replacePage in [false, true]) {
    testWidgets('late query preview_gone cannot end a ${replacePage ? 'replacement' : 'reloaded'} document', (tester) async {
      final updating = _UpdatingHost(host);
      host = updating;
      await open(tester);
      final origin = AppOrigin.forApp(config.scope, app.appId).origin;
      final oldReply = platform.pages.last.query(origin, 1);
      expect(updating.queries, hasLength(1));
      if (replacePage) {
        updating.next = replacement();
        await tester.tap(find.byTooltip('Обновить'));
        await tester.pump();
        await connect(tester, platform.pages.last);
      }
      await platform.pages.last.deliver(document);
      updating.queries.first.completeError(HostError('preview_gone', 'old review ended'));
      await tester.pump();
      expect(oldReply.messages, isEmpty);
      expect(find.text('К списку приложений'), findsNothing);
      expect(publishButton(tester).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('an old RPC completion cannot release the replacement gate pending limit', (tester) async {
    final updating = _UpdatingHost(host);
    host = updating;
    await open(tester);
    final origin = AppOrigin.forApp(config.scope, app.appId).origin;
    final oldReply = platform.pages.last.query(origin, 0);
    updating.next = replacement();
    await tester.tap(find.byTooltip('Обновить'));
    await tester.pump();
    final page = platform.pages.last;
    await connect(tester, page);
    await page.deliver(document);
    for (var id = 1; id <= maxPendingRpc; id++) {
      page.query(origin, id);
    }
    expect(updating.queries, hasLength(1 + maxPendingRpc));
    updating.queries.first.complete(QueryOutcome(reply: {}, fromCache: false));
    await tester.pump();
    expect(oldReply.messages, isEmpty);
    final refused = page.query(origin, 99);
    await tester.pump();
    expect(updating.queries, hasLength(1 + maxPendingRpc));
    expect(refused.messages.single['error']['code'], 'too_many_requests');
    for (final pending in updating.queries.skip(1)) {
      pending.complete(QueryOutcome(reply: {}, fromCache: false));
    }
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Back ignores an old controller result after a page replacement', (tester) async {
    final updating = _UpdatingHost(host);
    host = updating;
    await open(tester);
    final old = platform.pages.last;
    final back = Completer<bool>();
    old.native.back = back.future;
    await tester.pageBack();
    await tester.pump();
    updating.next = replacement();
    await tester.tap(find.byTooltip('Обновить'));
    await tester.pump();
    back.complete(true);
    await tester.pump();
    expect(old.native.backCalls, 0);
    expect(find.byType(SurfaceView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('signing blocks Back and installations, then a failure resumes updates', (tester) async {
    final updating = _UpdatingHost(host);
    host = updating;
    final response = Completer<String?>();
    decision = response.future;
    await open(tester);
    await tester.tap(find.text('Опубликовать'));
    await tester.pump();
    await confirm(tester);
    expect(approvals, 1);
    updating.next = replacement();
    await tester.pageBack();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(SurfaceView), findsOneWidget);
    expect(updating.updates, 0);
    response.complete('try again');
    await tester.pump();
    await tester.pump();
    expect(updating.updates, 1);
    expect(tester.widget<InAppWebView>(find.byType(InAppWebView)).key, const ValueKey(1));
    expect(publishButton(tester).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final exiting in [false, true]) {
    testWidgets('approval cannot pop another route while the preview is ${exiting ? 'exiting' : 'covered'}', (tester) async {
      final response = Completer<String?>();
      decision = response.future;
      await open(tester);
      await tester.tap(find.text('Опубликовать'));
      await tester.pump();
      await confirm(tester);
      expect(approvals, 1);
      final navigator = Navigator.of(tester.element(find.byType(SurfaceView)));
      if (exiting) navigator.pop();
      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Another route'))));
      await tester.pump(const Duration(milliseconds: 30));
      response.complete(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Another route'), findsOneWidget);
      expect(navigator.canPop(), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final status in [0, 401, 409, 500]) {
    testWidgets('rejection ${status == 0 ? 'offline' : status} is not reported as success', (tester) async {
      final response = Completer<void>();
      rejection = response.future;
      await open(tester);
      await tester.tap(find.text('Отклонить'));
      await tester.pump();
      response.completeError(status == 0 ? OfflineException('synthetic outage') : ApiException(status, 'synthetic refusal'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SurfaceView), findsOneWidget);
      expect(find.text('К списку приложений'), findsNothing);
      expect(find.text(status == 0 ? 'Нет связи с Hermes. Предпросмотр не отклонён.'
          : 'Не удалось отклонить: synthetic refusal'), findsOneWidget);
      expect(rejections, 1);
      expect(tester.widget<OutlinedButton>(find.ancestor(of: find.text('Отклонить'),
          matching: find.byType(OutlinedButton))).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('rejection 404 ends review without claiming a successful rejection', (tester) async {
    final response = Completer<void>();
    rejection = response.future;
    await open(tester);
    await tester.tap(find.text('Отклонить'));
    await tester.pump();
    response.completeError(ApiException(404, 'nothing awaiting review'));
    await tester.pump();
    expect(find.byType(SurfaceView), findsOneWidget);
    expect(find.text('К списку приложений'), findsOneWidget);
    expect(find.text('Отклонить'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rejection receives the displayed replacement instead of the menu target', (tester) async {
    final updating = _UpdatingHost(host);
    host = updating;
    await open(tester);
    final newer = replacement();
    updating.next = newer;
    await tester.tap(find.byTooltip('Обновить'));
    await tester.pump();
    await tester.tap(find.text('Отклонить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(rejections, 1);
    expect(rejected, same(newer));
    expect(find.byType(SurfaceView), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inflight refresh prevents signing and overlapping refreshes are coalesced', (tester) async {
    final updating = _UpdatingHost(host);
    host = updating;
    await open(tester);
    final refresh = Completer<InstalledApp?>();
    updating.delayed = refresh.future;
    await tester.tap(find.byTooltip('Обновить'));
    await tester.pump();
    expect(publishButton(tester).onPressed, isNull);
    await tester.tap(find.byTooltip('Обновить'));
    await tester.pump(const Duration(seconds: 2));
    expect(updating.updates, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(approvals, 0);
    refresh.complete(replacement());
    await tester.pump();
    await tester.pump();
    expect(tester.widget<InAppWebView>(find.byType(InAppWebView)).key, const ValueKey(1));
    expect(publishButton(tester).onPressed, isNull);
    await platform.pages.last.deliver(document);
    await tester.pump();
    expect(publishButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
}
