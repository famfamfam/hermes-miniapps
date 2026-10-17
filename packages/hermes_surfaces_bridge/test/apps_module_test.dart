import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

FakeBridge fixture(WidgetTester tester, SurfacesConnection? c, Responder respond) {
  final root = Directory.systemTemp.createTempSync('hermes_bridge_synthetic_');
  final bridge = FakeBridge(root, c, respond);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    });
    bridge.activeConnection.dispose();
  });
  return bridge;
}

void main() {
  test('immutable connections default to sealed network and derive versioned scopes', () {
    final a = connection();
    expect(a.scope, a.config.scope);
    expect(a.strictNetworkBlock, isTrue);
    expect(a.sealNetwork, isTrue);
    expect(a.scope, isNot(contains('synthetic')));
    expect(a.scope, isNot(connection(profile: 'profile_b').scope));
    expect(a.scope, isNot(connection(generation: 'generation_2').scope));
    expect(a.scope, isNot(connection(token: 'synthetic_rotated').scope));
    expect(a.scope, isNot(a.config.forPreview().scope));
    expect(a.config.forPreview().profileId, 'profile_a');
    expect(a.config.forPreview().credentialGeneration, 'generation_1');
  });

  testWidgets('unconfigured module embeds without another MaterialApp or identity/storage work', (tester) async {
    final bridge = fixture(tester, null, (_, _) => throw StateError('No network expected'));
    await mount(tester, bridge, embedded: true);
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.textContaining('Surfaces не настроены'), findsOneWidget);
    await tester.tap(find.text('Открыть чат'));
    await tester.pump();
    expect(bridge.chatCalls, 1);
    expect(bridge.supportReads, 0);
    expect(bridge.keyReads, 0);
    expect(bridge.clients, isEmpty);
    expect(bridge.root.listSync(), isEmpty);
  });

  testWidgets('invalid endpoint invalidates old Apps safely without blocking chat or sending credentials', (
    tester,
  ) async {
    final server = SyntheticServer();
    final bridge = fixture(tester, connection(), server.respond);
    await mount(tester, bridge);
    final supportReads = bridge.supportReads;
    final keyReads = bridge.keyReads;
    bridge.activeConnection.value = SurfacesConnection(
      config: ServerConfig(
        baseUri: Uri.parse('https://native-user:synthetic-secret@surfaces.example/'),
        token: 'synthetic-bearer',
        deviceId: 'synthetic-device',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(bridge.clients, hasLength(1));
    expect(bridge.clients.single.closes, 1);
    expect(bridge.supportReads, supportReads);
    expect(bridge.keyReads, keyReads);
    expect(find.text('Synthetic app'), findsNothing);
    expect(find.textContaining('адрес подключения'), findsOneWidget);
    expect(find.textContaining('synthetic-secret'), findsNothing);
    await tester.tap(find.text('Открыть чат'));
    expect(bridge.chatCalls, 1);
    await tester.runAsync(() async {
      bridge.activeConnection.value = connection(profile: 'profile_b');
    });
    await settle(tester);
    expect(find.text('Synthetic app'), findsOneWidget);
    expect(bridge.clients, hasLength(2));
  });

  testWidgets('list, verified install, native chat and Back use the existing host', (tester) async {
    final server = SyntheticServer();
    final c = connection();
    final bridge = fixture(tester, c, server.respond);
    SurfacePageRequest? page;
    await mount(
      tester,
      bridge,
      actions: [const Icon(Icons.settings)],
      pageBuilder: (_, request) {
        page = request;
        return FakePage(request: request);
      },
    );
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.text('Synthetic app'), findsOneWidget);
    expect(bridge.clients, hasLength(1));
    await open(tester, 'Synthetic app');
    expect(find.text('Synthetic page renderer'), findsOneWidget);
    expect(page!.app.bundleId, server.bundle.id);
    expect(page!.host.bundles.root.path, scopeRoot(bridge.root, c).path);
    expect(page!.connection.sealNetwork, isTrue);
    expect(page!.preview, isNull);
    expect(await tester.runAsync(() => page!.host.bundles.current('utilities')), isNotNull);
    await tester.tap(find.text('Открыть чат'));
    await tester.pump();
    expect(bridge.chatCalls, 1);
    expect(bridge.count('/devices/pair'), 0);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Back'));
    });
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Synthetic app'), findsOneWidget);
    expect(bridge.count('/apps'), 2, reason: 'returning refreshes the catalogue');
    expect(bridge.clients, hasLength(1), reason: 'refresh reuses the Apps session transport');
    expect(bridge.requests.every((r) => !r.followRedirects), isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(bridge.clients.single.closes, 1);
    expect(bridge.activeConnection.value, same(c), reason: 'Apps does not dispose/change the native notifier');
  });

  testWidgets('offline uses stable installed apps only in its exact scope, without adopting foreign files', (
    tester,
  ) async {
    final c = connection();
    final bridge = fixture(tester, c, (_, _) => throw http.ClientException('Synthetic offline'));
    final bundle = SyntheticBundle();
    final foreign = scopeRoot(bridge.root, connection(profile: 'profile_foreign'));
    await tester.runAsync(() async {
      await bundle.install(scopeRoot(bridge.root, c));
      await bundle.install(foreign, title: 'Foreign cached app');
    });
    SurfacePageRequest? page;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) {
        page = request;
        return FakePage(request: request);
      },
    );
    expect(find.text('Cached synthetic app'), findsOneWidget);
    expect(find.text('Foreign cached app'), findsNothing);
    expect(find.textContaining('Нет связи · данные от'), findsOneWidget);
    expect(find.text('Готово · работает без сети'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Обновить'));
    });
    await settle(tester);
    expect(find.text('Cached synthetic app'), findsOneWidget);
    await open(tester, 'Cached synthetic app');
    expect(page!.host.connectivity.value, Connectivity.offline);
    await tester.runAsync(() async {
      await expectLater(
        page!.host.query(page!.app, [
          {'name': 'synthetic', 'args': {}},
        ], timezone: 'UTC'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'offline_no_snapshot')),
      );
    });
    expect(await tester.runAsync(() => BundleStore(foreign).current('utilities')), isNotNull);
  });

  testWidgets('down server with no cache is nonfatal and native chat remains available', (tester) async {
    final bridge = fixture(tester, connection(), (_, _) => throw http.ClientException('Synthetic server down'));
    await mount(tester, bridge);
    expect(find.text('Приложений нет'), findsOneWidget);
    expect(find.text('Нет связи'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Открыть чат'));
    await tester.pump();
    expect(bridge.chatCalls, 1);
    expect(bridge.root.listSync(), isEmpty);
  });

  testWidgets('401 never presents cached/foreign data as live and never blocks chat', (tester) async {
    final c = connection();
    final bridge = fixture(tester, c, (_, _) => jsonResponse({'error': 'Synthetic rejected credential'}, 401));
    await tester.runAsync(() => SyntheticBundle().install(scopeRoot(bridge.root, c)));
    await mount(tester, bridge);
    expect(find.text('Cached synthetic app'), findsNothing);
    expect(find.textContaining('Сервер отклонил токен'), findsOneWidget);
    await tester.tap(find.text('Открыть чат'));
    await tester.pump();
    expect(bridge.chatCalls, 1);
    expect(await tester.runAsync(() => BundleStore(scopeRoot(bridge.root, c)).current('utilities')), isNotNull);
  });

  testWidgets('missing key still lists/opens previews but blocks both decisions without identity writes', (
    tester,
  ) async {
    final server = SyntheticServer(reviews: true);
    final bridge = fixture(tester, connection(), server.respond);
    SurfacePageRequest? page;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) {
        page = request;
        return FakePage(request: request);
      },
    );
    expect(find.text('Ждут вашего решения'), findsOneWidget);
    expect(find.textContaining('на устройстве нет ключа'), findsOneWidget);
    expect(bridge.count('/previews'), 1);
    expect(bridge.keyReads, 1);
    expect(bridge.root.listSync(), isEmpty, reason: 'a read-only catalogue creates no key or cache files');
    await open(tester, 'Synthetic preview');
    expect(page!.host.api, isA<PreviewApi>());
    expect(page!.connection.scope, bridge.activeConnection.value!.config.forPreview().scope);
    expect(page!.app.preview!.buildId, server.installedBuild);
    final message = await page!.preview!.approve(page!.app);
    expect(message, contains('на устройстве нет ключа'));
    await expectLater(page!.preview!.reject(page!.app), throwsA(isA<ApprovalFailure>()));
    expect(server.decisions, isEmpty);
    expect(bridge.count('/devices/pair'), 0);
    expect(File('${bridge.root.path}/approver_ed25519.key').existsSync(), isFalse);
    expect(bridge.root.listSync().every((e) => e is Directory && e.path.endsWith('surfaces')), isTrue);
  });

  testWidgets('read-only listing is independent of a pending identity callback', (tester) async {
    final server = SyntheticServer(reviews: true);
    final bridge = fixture(tester, connection(), server.respond);
    final key = Completer<ApproverKey?>();
    bridge.readKey = () => key.future;
    await mount(tester, bridge);
    expect(find.text('Synthetic preview'), findsOneWidget);
    expect(find.textContaining('ключ устройства ещё загружается'), findsOneWidget);
    key.complete(null);
    await tester.pump();
    expect(find.textContaining('на устройстве нет ключа'), findsOneWidget);
    expect(bridge.root.listSync(), isEmpty);
  });

  testWidgets('identity callback failure is explicit but does not prevent read-only previews', (tester) async {
    final server = SyntheticServer(reviews: true);
    final bridge = fixture(tester, connection(), server.respond);
    bridge.readKey = () async => throw const FormatException('Synthetic invalid identity');
    await mount(tester, bridge);
    expect(find.text('Synthetic preview'), findsOneWidget);
    expect(find.textContaining('не удалось загрузить существующий ключ'), findsOneWidget);
    expect(bridge.count('/devices/pair'), 0);
    expect(bridge.root.listSync(), isEmpty);
  });

  for (final failed in [false, true]) {
    testWidgets('refresh reloads an existing identity after native setup (previous failure: $failed)', (tester) async {
      final server = SyntheticServer(reviews: true);
      final bridge = fixture(tester, connection(), server.respond);
      if (failed) bridge.readKey = () async => throw const FormatException('Synthetic invalid identity');
      SurfacePageRequest? page;
      await mount(
        tester,
        bridge,
        pageBuilder: (_, request) {
          page = request;
          return FakePage(request: request);
        },
      );
      expect(bridge.keyReads, 1);
      expect(find.textContaining('Подтверждение отключено'), findsOneWidget);
      final binding = bridge.activeConnection.value;
      bridge.readKey = null;
      bridge.key = await ApproverKey.fromSeed(Uint8List(32));
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Обновить'));
      });
      await settle(tester);
      expect(bridge.activeConnection.value, same(binding));
      expect(bridge.keyReads, 2);
      expect(find.textContaining('Подтверждение отключено'), findsNothing);
      expect(bridge.count('/previews'), 2);
      await open(tester, 'Synthetic preview');
      expect(await page!.preview!.approve(page!.app), isNull);
      expect(bridge.count('/devices/pair'), 0);
      expect(File('${bridge.root.path}/approver_ed25519.key').existsSync(), isFalse);
    });
  }

  testWidgets('native approval/rejection use displayed metadata, synthetic root-seed callback writes no key', (
    tester,
  ) async {
    final server = SyntheticServer(reviews: true);
    final c = connection();
    final bridge = fixture(tester, c, server.respond);
    bridge.key = await ApproverKey.fromSeed(Uint8List(32));
    SurfacePageRequest? page;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) {
        page = request;
        return FakePage(request: request);
      },
    );
    await tester.runAsync(
      () => server.bundle.install(scopeRoot(bridge.root, c), title: 'Published cache stays intact'),
    );
    await open(tester, 'Synthetic preview');
    expect(page!.app.preview!.buildId, isNot(server.listedBuild));
    expect(await page!.preview!.approve(page!.app), isNull);
    await page!.preview!.reject(page!.app);
    final approved = jsonDecode(server.decisions.firstWhere((r) => r.url.path.endsWith('/approve')).body) as Map;
    final rejected = jsonDecode(server.decisions.firstWhere((r) => r.url.path.endsWith('/reject')).body) as Map;
    expect(approved['buildId'], server.installedBuild);
    expect(approved['signature'], isA<String>());
    expect(rejected['buildId'], server.installedBuild);
    expect(bridge.count('/devices/pair'), 0);
    expect(File('${bridge.root.path}/approver_ed25519.key').existsSync(), isFalse);
    final published = await tester.runAsync(() => BundleStore(scopeRoot(bridge.root, c)).current('utilities'));
    expect(published!.title, 'Published cache stays intact');
    expect(published.preview, isNull);
    expect(published.revision, 3);
    expect(page!.host.bundles.root.path, isNot(scopeRoot(bridge.root, c).path));
  });

  testWidgets('a page gets the host\'s file actions and a chat starter that stops working with its session', (
    tester,
  ) async {
    final server = SyntheticServer();
    final bridge = fixture(tester, connection(), server.respond);
    final actions = _NoActions();
    final sent = <String>[];
    bridge.files = actions;
    bridge.send = (text) async {
      sent.add(text);
      return true;
    };
    SurfacePageRequest? page;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) {
        page = request;
        return FakePage(request: request);
      },
    );
    await open(tester, 'Synthetic app');
    expect(identical(page!.fileActions, actions), isTrue);
    expect(await page!.sendToHermes!('Разбери квитанцию'), isTrue);
    expect(sent, ['Разбери квитанцию']);

    bridge.activeConnection.value = connection(profile: 'profile_b');
    await tester.pump();
    expect(await page!.sendToHermes!('too late'), isFalse, reason: 'the page belongs to a connection that is gone');
    expect(sent, ['Разбери квитанцию']);
  });

  testWidgets('the API a page works through really reaches the server for files (not a stub of the bound API)', (
    tester,
  ) async {
    final server = SyntheticServer();
    final calls = <String>[];
    final bridge = fixture(tester, connection(), (req, c) {
      final path = req.url.path;
      if (path.endsWith('/apps/utilities/files')) {
        calls.add('${req.method} files');
        return jsonResponse({
          'files': [
            {'fileId': 'f_0123456789abcdef', 'name': 'a.pdf', 'mime': 'application/pdf', 'size': 3, 'createdAt': 'x'},
          ],
        });
      }
      if (path.endsWith('/apps/utilities/downloads/receipt_file')) {
        calls.add('${req.method} download ${req.body}');
        return http.Response.bytes([37, 80, 68, 70], 200, headers: {'content-type': 'application/pdf', 'x-file-name': 'r.pdf'});
      }
      return server.respond(req, c);
    });
    SurfacePageRequest? page;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) {
        page = request;
        return FakePage(request: request);
      },
    );
    await open(tester, 'Synthetic app');
    final listed = await tester.runAsync(() => page!.host.api.listFiles('utilities'));
    expect(listed!.single.fileId, 'f_0123456789abcdef');
    final file = await tester.runAsync(
      () => page!.host.api.downloadNamed('utilities', 3, 'receipt_file', {'id': 19}, timezone: 'UTC'),
    );
    expect(file!.bytes, [37, 80, 68, 70]);
    expect(file.name, 'r.pdf');
    expect(calls, hasLength(2));
    expect(calls.last, contains('"id":19'));
  });
  testWidgets('a host that offers neither leaves the page without both', (tester) async {
    final server = SyntheticServer();
    final bridge = fixture(tester, connection(), server.respond);
    SurfacePageRequest? page;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) {
        page = request;
        return FakePage(request: request);
      },
    );
    await open(tester, 'Synthetic app');
    expect(page!.fileActions, isNull);
    expect(page!.sendToHermes, isNull);
  });

  testWidgets('profile then credential changes synchronously close owned transports and dispose native pages', (
    tester,
  ) async {
    final server = SyntheticServer(reviews: true);
    final a = connection();
    final bridge = fixture(tester, a, server.respond);
    bridge.key = await ApproverKey.fromSeed(Uint8List(32));
    final unrelated = FakeClient(a, server.respond);
    SurfacePageRequest? oldPage;
    var disposals = 0;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) {
        oldPage = request;
        return FakePage(request: request, onDispose: () => disposals++);
      },
    );
    await open(tester, 'Synthetic preview');
    final before = bridge.requests.length;
    expect(bridge.clients, hasLength(2));
    bridge.activeConnection.value = connection(profile: 'profile_b');
    expect(bridge.clients.take(2).every((c) => c.closes == 1), isTrue, reason: 'close happens before a frame');
    await tester.pump();
    expect(disposals, 1);
    expect(find.text('Synthetic page renderer'), findsNothing);
    expect(find.textContaining('Подключение изменилось'), findsOneWidget);
    expect(await oldPage!.preview!.approve(oldPage!.app), contains('Подключение изменилось'));
    await expectLater(oldPage!.preview!.reject(oldPage!.app), throwsA(isA<ApprovalFailure>()));
    await oldPage!.openChat();
    expect(bridge.chatCalls, 0);
    await expectLater(oldPage!.host.api.events(since: 0, epoch: ''), throwsA(isA<OfflineException>()));
    expect(bridge.requests.take(before).length, before);
    expect(bridge.clients.take(2).expand((c) => c.requests).length, before, reason: 'closed old APIs send nothing');
    expect(unrelated.closes, 0);
    // Switch again while the original route is still open. Chat belongs to the current host.
    bridge.activeConnection.value = connection(profile: 'profile_b', generation: 'generation_2');
    await tester.pump();
    await tester.tap(find.text('Открыть чат'));
    await tester.pump();
    expect(bridge.chatCalls, 1);
    expect(disposals, 1);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Back'));
    });
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Synthetic app'), findsOneWidget);
    expect(bridge.clients.last.connection.config.credentialGeneration, 'generation_2');
    expect(
      await tester.runAsync(() => BundleStore(scopeRoot(bridge.root, a, preview: true)).current('utilities')),
      isNotNull,
      reason: 'switch preserves old scopes; it does not delete or adopt them',
    );
    unrelated.close();
  });

  testWidgets('approval in flight cannot send after a binding switch, even when transport close is permissive', (
    tester,
  ) async {
    final server = SyntheticServer(reviews: true);
    final challenge = Completer<http.Response>();
    final bridge = fixture(
      tester,
      connection(),
      (req, c) => req.url.path.endsWith('/challenge') ? challenge.future : server.respond(req, c),
    );
    bridge.key = await ApproverKey.fromSeed(Uint8List(32));
    SurfacePageRequest? page;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) {
        page = request;
        return FakePage(request: request);
      },
    );
    await open(tester, 'Synthetic preview');
    final approving = page!.preview!.approve(page!.app);
    await tester.pump();
    expect(bridge.count('/previews/utilities/challenge'), 1);
    bridge.activeConnection.value = connection(profile: 'profile_b');
    challenge.complete(
      server.respond(bridge.requests.firstWhere((r) => r.url.path.endsWith('/challenge')), connection())
          as http.Response,
    );
    expect(await approving, isNotNull);
    await tester.pump();
    expect(bridge.count('/previews/utilities/approve'), 0);
  });

  for (final latePath in ['/devices/hello', '/apps', '/previews']) {
    testWidgets('late $latePath results are dropped over two binding changes', (tester) async {
      final server = SyntheticServer(reviews: true);
      final late = Completer<http.Response>();
      final a = connection();
      final bridge = fixture(tester, a, (req, c) {
        if (c.config.profileId == 'profile_a' && req.url.path.endsWith(latePath)) {
          return late.future;
        }
        if (req.url.path.endsWith('/apps')) {
          return jsonResponse({
            'apps': [
              {
                'appId': 'utilities',
                'title': 'Catalogue ${c.config.profileId} ${c.config.credentialGeneration}',
                'revision': 3,
              },
            ],
          });
        }
        return server.respond(req, c);
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(localizedApp(home: AppsModule(bridge: bridge, autoSync: false)));
        for (var i = 0; i < 100 && bridge.count(latePath) == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(bridge.count(latePath), 1);
      await tester.runAsync(() async {
        bridge.activeConnection.value = connection(profile: 'profile_b');
      });
      await settle(tester);
      expect(find.text('Catalogue profile_b generation_1'), findsOneWidget);
      await tester.runAsync(() async {
        bridge.activeConnection.value = connection(profile: 'profile_b', generation: 'generation_2');
      });
      await settle(tester);
      late.complete(
        server.respond(bridge.clients.first.requests.firstWhere((r) => r.url.path.endsWith(latePath)), a)
            as http.Response,
      );
      await tester.pumpAndSettle();
      expect(find.text('Catalogue profile_b generation_2'), findsOneWidget);
      expect(find.text('Synthetic app'), findsNothing);
      expect(bridge.clients.take(2).every((c) => c.closes == 1), isTrue);
      expect(bridge.clients.last.closes, 0);
    });
  }

  testWidgets('late preview download never navigates or installs into the newly selected binding', (tester) async {
    final server = SyntheticServer(reviews: true);
    final download = Completer<http.Response>();
    final a = connection();
    final bridge = fixture(tester, a, (req, c) {
      if (c.config.profileId == 'profile_a' && req.url.path.contains('/previews/utilities/bundles/')) {
        return download.future;
      }
      return server.respond(req, c);
    });
    var pageBuilds = 0;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) {
        pageBuilds++;
        return FakePage(request: request);
      },
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Synthetic preview'));
      for (var i = 0; i < 100 && bridge.clients.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    expect(bridge.requests.any((r) => r.url.path.contains('/previews/utilities/bundles/')), isTrue);
    await tester.runAsync(() async {
      bridge.activeConnection.value = connection(profile: 'profile_b');
    });
    await settle(tester);
    await tester.runAsync(() async {
      bridge.activeConnection.value = connection(profile: 'profile_b', generation: 'generation_2');
    });
    await settle(tester);
    download.complete(http.Response.bytes(server.bundle.zip, 200));
    await tester.pumpAndSettle();
    expect(pageBuilds, 0);
    expect(find.text('Synthetic preview'), findsOneWidget);
    expect(bridge.clients.take(2).every((c) => c.closes == 1), isTrue);
    expect(
      await tester.runAsync(() => BundleStore(scopeRoot(bridge.root, a, preview: true)).current('utilities')),
      isNull,
    );
    expect(
      await tester.runAsync(
        () => BundleStore(scopeRoot(bridge.root, bridge.activeConnection.value!, preview: true)).current('utilities'),
      ),
      isNull,
    );
  });

  testWidgets('A to B to A never revives an old route or its callbacks', (tester) async {
    final server = SyntheticServer();
    final a = connection();
    final bridge = fixture(tester, a, server.respond);
    SurfacePageRequest? page;
    var disposals = 0;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) {
        page = request;
        return FakePage(request: request, onDispose: () => disposals++);
      },
    );
    await open(tester, 'Synthetic app');
    bridge.activeConnection.value = connection(profile: 'profile_b');
    bridge.activeConnection.value = a;
    await tester.pump();
    expect(disposals, 1);
    expect(find.textContaining('Подключение изменилось'), findsOneWidget);
    await page!.openChat();
    expect(bridge.chatCalls, 0);
    expect(bridge.clients.first.closes, 1);
  });

  testWidgets('automatic preview refresh never overlaps and 401 clears previews/catalogue', (tester) async {
    final server = SyntheticServer(reviews: true);
    final pending = Completer<http.Response>();
    var reads = 0;
    final bridge = fixture(tester, connection(), (req, c) {
      if (req.url.path.endsWith('/previews') && ++reads > 1) return pending.future;
      return server.respond(req, c);
    });
    await mount(tester, bridge);
    expect(bridge.count('/previews'), 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(bridge.count('/previews'), 2, reason: 'one pending poll; the next timer tick must skip');
    pending.complete(jsonResponse({'error': 'Synthetic unauthorized'}, 401));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic preview'), findsNothing);
    expect(find.text('Synthetic app'), findsNothing);
    expect(find.textContaining('Сервер отклонил токен'), findsOneWidget);
    await tester.tap(find.text('Открыть чат'));
    await tester.pump();
    expect(bridge.chatCalls, 1);
    bridge.activeConnection.value = null;
    await tester.pump(const Duration(seconds: 15));
    expect(bridge.count('/previews'), 2, reason: 'old polling timer is cancelled');
  });

  testWidgets('a catalogue that came up offline recovers on its own once the server answers', (tester) async {
    final server = SyntheticServer();
    var reachable = false;
    final bridge = fixture(tester, connection(), (req, c) {
      if (!reachable) throw http.ClientException('Synthetic first request lost');
      return server.respond(req, c);
    });
    await mount(tester, bridge);
    expect(find.text('Synthetic app'), findsNothing);
    expect(find.textContaining('Нет связи'), findsWidgets);
    reachable = true;
    await tester.pump(const Duration(seconds: 5));
    // The retry is quiet (no spinner, cards stay enabled), so wait for its result instead of for a spinner.
    for (var i = 0; i < 300 && find.text('Synthetic app').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Synthetic app'), findsOneWidget);
    expect(find.textContaining('Онлайн'), findsWidgets);
  });

  testWidgets('preview read failure during catalogue refresh is not overwritten as online', (tester) async {
    final server = SyntheticServer(reviews: true);
    final bridge = fixture(
      tester,
      connection(),
      (req, c) => req.url.path.endsWith('/previews')
          ? jsonResponse({'error': 'Synthetic unauthorized'}, 401)
          : server.respond(req, c),
    );
    await mount(tester, bridge);
    expect(find.text('Synthetic app'), findsNothing);
    expect(find.text('Synthetic preview'), findsNothing);
    expect(find.textContaining('Сервер отклонил токен'), findsOneWidget);
  });

  testWidgets('host factory receives scoped preview config, errors are controlled and refresh reads once', (
    tester,
  ) async {
    final server = SyntheticServer(reviews: true);
    final bridge = fixture(tester, connection(), server.respond);
    final factoryCalls = <(SurfacesConnection, Directory, bool)>[];
    Future<SurfacesHost> factory(SurfacesConnection c, Directory root, bool preview) async {
      factoryCalls.add((c, root, preview));
      final client = bridge.createSurfacesClient(c);
      return SurfacesHost(
        api: preview ? _BrokenPreview(c.config, client: client) : SurfacesApi(c.config, client: client),
        bundles: BundleStore(root),
        snapshots: SnapshotCache(root),
      );
    }

    await mount(tester, bridge, hostFactory: factory);
    expect(bridge.count('/previews'), 1);
    await open(tester, 'Synthetic preview');
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Манифест отклонён: synthetic malformed preview'), findsOneWidget);
    expect(find.byType(SurfaceView), findsNothing);
    expect(bridge.count('/health'), 2);
    expect(bridge.count('/previews'), 2);
    expect(factoryCalls, hasLength(2));
    expect(factoryCalls.last.$3, isTrue);
    expect(factoryCalls.last.$1.config.connectionId, 'synthetic_connection');
    expect(factoryCalls.last.$1.scope, bridge.activeConnection.value!.config.forPreview().scope);
    expect(factoryCalls.last.$2.path, scopeRoot(bridge.root, bridge.activeConnection.value!, preview: true).path);
    await tester.pumpWidget(const SizedBox());
    expect(bridge.clients.every((c) => c.closes == 1), isTrue);
  });

  testWidgets('a failed preview host factory can be retried without replacing the binding', (tester) async {
    final server = SyntheticServer(reviews: true);
    final bridge = fixture(tester, connection(), server.respond);
    var attempts = 0;
    await mount(
      tester,
      bridge,
      pageBuilder: (_, request) => FakePage(request: request),
      previewHostFactory: (c, root, preview) async {
        if (++attempts == 1) throw StateError('Synthetic factory failure');
        return SurfacesHost(
          api: PreviewApi(c.config, client: bridge.createSurfacesClient(c)),
          bundles: BundleStore(root),
          snapshots: SnapshotCache(root),
        );
      },
    );
    await open(tester, 'Synthetic preview');
    await settle(tester);
    expect(find.text('Не удалось открыть приложение'), findsOneWidget);
    await open(tester, 'Synthetic preview');
    expect(find.text('Synthetic page renderer'), findsOneWidget);
    expect(attempts, 2);
    expect(bridge.clients, hasLength(2));
  });

  testWidgets('late custom factory return is closed and discarded', (tester) async {
    final server = SyntheticServer();
    final a = connection();
    final bridge = fixture(tester, a, server.respond);
    final late = Completer<SurfacesHost>();
    final staleClient = FakeClient(a, server.respond);
    var factoryStarted = false;
    final staleApi = SurfacesApi(a.config, client: staleClient);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        localizedApp(
          home: AppsModule(
            bridge: bridge,
            autoSync: false,
            hostFactory: (c, root, preview) async {
              if (c.config.profileId == 'profile_a') {
                factoryStarted = true;
                return late.future;
              }
              return SurfacesHost(
                api: SurfacesApi(c.config, client: bridge.createSurfacesClient(c)),
                bundles: BundleStore(root),
                snapshots: SnapshotCache(root),
              );
            },
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    expect(factoryStarted, isTrue);
    await tester.runAsync(() async {
      bridge.activeConnection.value = connection(profile: 'profile_b');
    });
    await settle(tester);
    late.complete(
      SurfacesHost(
        api: staleApi,
        bundles: BundleStore(scopeRoot(bridge.root, a)),
        snapshots: SnapshotCache(scopeRoot(bridge.root, a)),
      ),
    );
    await tester.pump();
    expect(staleClient.closes, 1);
    expect(staleClient.requests, isEmpty);
    expect(find.text('Synthetic app'), findsOneWidget);
  });
}

class _BrokenPreview extends PreviewApi {
  _BrokenPreview(super.config, {super.client});
  @override
  Future<AppManifest> manifest(String appId) async => throw ManifestException('synthetic malformed preview');
}

class _NoActions extends HostFileActions {
  @override
  Future<PickedFile?> pick(BuildContext context, {required List<String> accept}) async => null;

  @override
  Future<FileOfferResult> offer(BuildContext context, {required String name, required String mime, required Uint8List bytes}) async =>
      FileOfferResult.cancelled;
}
