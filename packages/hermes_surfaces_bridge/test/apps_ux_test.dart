import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:hermes_surfaces_bridge/src/apps_widgets.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

/// Presentation of the Apps screen: header, single status chip, cards, pull-to-refresh, onboarding.
/// The security/lifecycle behaviour behind it stays covered by apps_module_test.dart.

const chipKey = ValueKey('apps-status-chip');

FakeBridge fixture(WidgetTester tester, SurfacesConnection? c, Responder respond) {
  final root = Directory.systemTemp.createTempSync('hermes_bridge_ux_');
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

Future<void> mountUx(
  WidgetTester tester,
  FakeBridge bridge, {
  bool embedded = true,
  VoidCallback? onConfigure,
  SurfacesText? hostNotice,
  bool hostBusy = false,
  HostFactory? hostFactory,
  bool autoSync = false,
  double textScale = 1.0,
  VoidCallback? onPasteCode,
  bool showChat = true,
  bool active = true,
}) async {
  await tester.pumpWidget(
    localizedApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: AppsModule(
          bridge: bridge,
          embedded: embedded,
          onConfigure: onConfigure,
          onPasteCode: onPasteCode,
          hostNotice: hostNotice,
          hostBusy: hostBusy,
          hostFactory: hostFactory,
          autoSync: autoSync,
          showChat: showChat,
          active: active,
          surfacePageBuilder: (_, request) => FakePage(request: request),
        ),
      ),
    ),
  );
  await settle(tester);
}

void phone(WidgetTester tester, {double width = 411, double height = 892}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> tapRefresh(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.byTooltip('Обновить'));
  });
  await settle(tester);
}

Finder inCards(Finder inner) => find.descendant(of: find.byType(ListTile), matching: inner);

void main() {
  group('header and single status chip', () {
    testWidgets('one action row, labelled where it fits, ONE online chip and no duplicate status text', (tester) async {
      final bridge = fixture(tester, connection(), SyntheticServer().respond);
      await mountUx(tester, bridge, onConfigure: () {});
      expect(find.byKey(chipKey), findsOneWidget);
      expect(find.text('Онлайн'), findsOneWidget);
      expect(find.text('Сервер доступен'), findsNothing, reason: 'the old brown status bar is gone');
      final chat = tester.getCenter(find.text('Открыть чат'));
      expect(tester.getCenter(find.text('Обновить')).dy, chat.dy, reason: 'one row');
      expect(tester.getCenter(find.text('Настройки')).dy, chat.dy, reason: 'one row');
      expect(tester.getTopLeft(find.byKey(chipKey)).dy, greaterThan(chat.dy));
      expect(find.byTooltip('Обновить'), findsOneWidget);
      expect(find.byTooltip('Настроить Surfaces'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('icon-only actions keep 48dp targets and tooltips on a narrow, scaled screen', (tester) async {
      phone(tester, width: 320, height: 640);
      final bridge = fixture(tester, connection(), SyntheticServer().respond);
      await mountUx(tester, bridge, onConfigure: () {}, textScale: 1.3);
      expect(find.text('Обновить'), findsNothing);
      expect(find.text('Настройки'), findsNothing);
      expect(find.text('Открыть чат'), findsOneWidget);
      for (final tooltip in ['Обновить', 'Настроить Surfaces']) {
        final size = tester.getSize(find.byTooltip(tooltip));
        expect(size.width, greaterThanOrEqualTo(48), reason: tooltip);
        expect(size.height, greaterThanOrEqualTo(48), reason: tooltip);
      }
      final chat = find.ancestor(
        of: find.text('Открыть чат'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      );
      expect(tester.getSize(chat).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });

    testWidgets('offline chip shows the time of the last data, then the app rows say they work offline', (
      tester,
    ) async {
      final server = SyntheticServer();
      var down = false;
      final bridge = fixture(tester, connection(), (req, c) {
        if (down) throw http.ClientException('Synthetic offline');
        return server.respond(req, c);
      });
      Future<SurfacesHost> factory(SurfacesConnection c, Directory root, bool preview) async {
        final client = bridge.createSurfacesClient(c);
        return SurfacesHost(
          api: preview ? PreviewApi(c.config, client: client) : SurfacesApi(c.config, client: client),
          bundles: BundleStore(root),
          snapshots: SnapshotCache(root),
          clock: () => DateTime(2026, 10, 15, 12, 19),
        );
      }

      await mountUx(tester, bridge, hostFactory: factory);
      expect(find.text('Онлайн'), findsOneWidget);
      await tester.runAsync(() => server.bundle.install(scopeRoot(bridge.root, bridge.activeConnection.value!)));
      down = true;
      await tapRefresh(tester);
      expect(find.text('Нет связи · данные от 12:19'), findsOneWidget);
      expect(find.text('Онлайн'), findsNothing);
      expect(find.text('Готово · работает без сети'), findsOneWidget);
    });

    testWidgets('401 is one error chip plus ONE actionable card; rows are not shown as live', (tester) async {
      var configure = 0;
      final bridge = fixture(tester, connection(), (_, _) => jsonResponse({'error': 'synthetic server body'}, 401));
      await mountUx(tester, bridge, onConfigure: () => configure++);
      expect(find.text('Сервер отклонил токен'), findsOneWidget);
      expect(find.text('Нет доступа к Surfaces'), findsOneWidget);
      expect(find.textContaining('synthetic server body'), findsNothing);
      expect(find.text('Настроить Surfaces'), findsOneWidget, reason: 'one configure control, not header + card');
      expect(find.text('Настройки'), findsNothing);
      expect(find.text('Повторить'), findsOneWidget);
      await tester.tap(find.text('Настроить Surfaces'));
      expect(configure, 1);
      await tester.tap(find.text('Открыть чат'));
      expect(bridge.chatCalls, 1);
    });

    testWidgets('a server error with nothing cached is an error chip and a retry, without echoing the body', (
      tester,
    ) async {
      final server = SyntheticServer();
      var broken = true;
      final bridge = fixture(tester, connection(), (req, c) {
        if (broken && req.url.path.endsWith('/apps')) return jsonResponse({'error': 'synthetic stack trace'}, 500);
        return server.respond(req, c);
      });
      await mountUx(tester, bridge);
      expect(find.text('Ошибка Surfaces'), findsOneWidget);
      expect(find.text('Не удалось загрузить приложения'), findsOneWidget);
      expect(find.textContaining('synthetic stack trace'), findsNothing);
      broken = false;
      await tester.runAsync(() async {
        await tester.tap(find.text('Повторить'));
      });
      await settle(tester);
      expect(find.text('Онлайн'), findsOneWidget);
      expect(find.text('Synthetic app'), findsOneWidget);
    });

    testWidgets('not configured without a host hook is one card, no button and no request', (tester) async {
      final bridge = fixture(tester, null, (_, _) => throw StateError('No network expected'));
      await mountUx(tester, bridge);
      expect(find.text('Не настроено'), findsOneWidget);
      expect(find.text('Surfaces не настроены'), findsOneWidget);
      expect(find.textContaining('Подключение настраивается в основном приложении'), findsOneWidget);
      expect(find.text('Настроить Surfaces'), findsNothing);
      expect(find.text('Открыть чат'), findsOneWidget);
      expect(bridge.clients, isEmpty);
    });

    testWidgets('an invalid address never echoes its userinfo and offers the configure action', (tester) async {
      final bridge = fixture(
        tester,
        SurfacesConnection(
          config: ServerConfig(
            baseUri: Uri.parse('https://native-user:synthetic-secret@surfaces.example/'),
            token: 'synthetic-bearer',
            deviceId: 'synthetic-device',
          ),
        ),
        (_, _) => throw StateError('No network expected'),
      );
      var configure = 0;
      await mountUx(tester, bridge, onConfigure: () => configure++);
      expect(find.text('Неверный адрес'), findsOneWidget);
      expect(find.textContaining('адрес подключения'), findsOneWidget);
      expect(find.textContaining('synthetic-secret'), findsNothing);
      expect(find.textContaining('synthetic-bearer'), findsNothing);
      await tester.tap(find.text('Настроить Surfaces'));
      expect(configure, 1);
      expect(bridge.clients, isEmpty);
    });

    testWidgets('a host notice is shown verbatim once; a busy host says connecting, not unconfigured', (tester) async {
      final bridge = fixture(tester, null, (_, _) => throw StateError('No network expected'));
      await mountUx(tester, bridge, onConfigure: () {}, hostNotice: SurfacesText.noticeTargetChanged);
      expect(find.text('Недоступно'), findsOneWidget);
      expect(find.text('Подключение изменилось. Откройте приложения заново.'), findsOneWidget);
      expect(find.text('Surfaces не настроены'), findsNothing);
      expect(find.text('Настройки'), findsOneWidget, reason: 'configuration stays reachable from the header');
      await mountUx(tester, bridge, onConfigure: () {}, hostBusy: true);
      expect(find.text('Подключаюсь…'), findsOneWidget);
      expect(find.text('Surfaces не настроены'), findsNothing);
    });
  });

  group('app cards', () {
    testWidgets('state subtitle, avatar and ONE trailing affordance that matches tapping the card', (tester) async {
      final server = SyntheticServer();
      final bridge = fixture(tester, connection(), server.respond);
      await mountUx(tester, bridge);
      expect(find.text('Нужно скачать · откроется после загрузки'), findsOneWidget);
      expect(find.text('не скачано · ревизия 3'), findsNothing, reason: 'the old technical subtitle is gone');
      expect(find.text('S'), findsOneWidget, reason: 'avatar initial');
      expect(inCards(find.byIcon(Icons.cloud_download_outlined)), findsOneWidget);
      expect(inCards(find.byIcon(Icons.download_outlined)), findsNothing);
      // The trailing icon is not a separate button: tapping it is tapping the card.
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.cloud_download_outlined));
      });
      for (var i = 0; i < 300 && find.text('Synthetic page renderer').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(find.text('Synthetic page renderer'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Back'));
      });
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Готово · работает без сети'), findsOneWidget);
      expect(inCards(find.byIcon(Icons.chevron_right)), findsOneWidget);
      expect(inCards(find.byIcon(Icons.cloud_download_outlined)), findsNothing);
      // A newer server revision is announced plainly.
      server.revision = 4;
      await tapRefresh(tester);
      expect(find.text('Доступно обновление ревизии 4'), findsOneWidget);
    });

    testWidgets('autoSync downloads new apps in the background, no tap needed, and updates on a timer', (
      tester,
    ) async {
      final server = SyntheticServer();
      final bridge = fixture(tester, connection(), server.respond);
      await mountUx(tester, bridge, autoSync: true);
      for (var i = 0; i < 300 && find.text('Готово · работает без сети').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Готово · работает без сети'), findsOneWidget);
      expect(find.text('Нужно скачать · откроется после загрузки'), findsNothing);
      expect(inCards(find.byIcon(Icons.cloud_download_outlined)), findsNothing);

      // A newer revision on the server is picked up by the half-minute re-read and downloaded too.
      server.revision = 4;
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      for (var i = 0; i < 300 && find.text('Доступно обновление ревизии 4').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Доступно обновление ревизии 4'), findsOneWidget, reason: 'announced without a manual refresh');
    });

    testWidgets('a retry against an unreachable server leaves the saved apps tappable', (tester) async {
      final server = SyntheticServer();
      var mode = 'online';
      final hang = Completer<http.Response>();
      final bridge = fixture(tester, connection(), (req, c) {
        if (mode == 'offline') throw http.ClientException('Synthetic offline');
        if (mode == 'hang') return hang.future; // the server stops answering: a request waits for its timeout
        return server.respond(req, c);
      });
      await mountUx(tester, bridge);
      await open(tester, 'Synthetic app'); // installs the app while online
      await tester.pageBack();
      await settle(tester);
      mode = 'offline';
      await tapRefresh(tester);
      mode = 'hang';
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 5)); // the offline catalogue retries on this timer
      }
      final card = find.ancestor(of: find.text('Synthetic app installed'), matching: find.byType(ListTile)).first;
      expect(tester.widget<ListTile>(card).onTap, isNotNull, reason: 'a hanging retry must not disable the cards');
      hang.complete(http.Response('{}', 500));
      await tester.pump();
    });
    testWidgets('inline progress while the bundle downloads; other cards stay inert', (tester) async {
      final server = SyntheticServer();
      final download = Completer<http.Response>();
      final bridge = fixture(
        tester,
        connection(),
        (req, c) => req.url.path.contains('/bundles/') ? download.future : server.respond(req, c),
      );
      await mountUx(tester, bridge);
      await tester.runAsync(() async {
        await tester.tap(find.text('Synthetic app'));
        // Wait for the held download request itself, not for a guessed delay.
        for (var i = 0; i < 300 && !bridge.requests.any((r) => r.url.path.contains('/bundles/')); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      expect(find.text('Скачиваю…'), findsOneWidget);
      expect(inCards(find.byType(CircularProgressIndicator)), findsOneWidget);
      expect(find.text('Нужно скачать · откроется после загрузки'), findsNothing);
      download.complete(http.Response.bytes(server.bundle.zip, 200));
      for (var i = 0; i < 300 && find.text('Synthetic page renderer').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(find.text('Synthetic page renderer'), findsOneWidget);
    });

    testWidgets('a failed open is an error state on that card with retry, cleared once it succeeds', (tester) async {
      final server = SyntheticServer();
      var failing = true;
      final bridge = fixture(tester, connection(), (req, c) {
        if (failing && req.url.path.endsWith('/apps/utilities')) {
          return jsonResponse({'error': 'synthetic manifest failure'}, 500);
        }
        return server.respond(req, c);
      });
      await mountUx(tester, bridge);
      await open(tester, 'Synthetic app');
      await settle(tester);
      expect(inCards(find.text('synthetic manifest failure')), findsOneWidget);
      expect(find.text('Нажмите, чтобы повторить'), findsOneWidget);
      expect(inCards(find.byIcon(Icons.refresh)), findsOneWidget);
      expect(find.text('Нужно скачать · откроется после загрузки'), findsNothing);
      failing = false;
      await open(tester, 'Synthetic app');
      expect(find.text('Synthetic page renderer'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Back'));
      });
      await settle(tester);
      await tester.pumpAndSettle();
      expect(inCards(find.text('synthetic manifest failure')), findsNothing, reason: 'the toast may still be up');
      expect(find.text('Готово · работает без сети'), findsOneWidget);
    });

    testWidgets('an error belongs to the revision it happened at', (tester) async {
      final server = SyntheticServer();
      final bridge = fixture(tester, connection(), (req, c) {
        if (req.url.path.endsWith('/apps/utilities')) return jsonResponse({'error': 'synthetic failure'}, 500);
        return server.respond(req, c);
      });
      await mountUx(tester, bridge);
      await open(tester, 'Synthetic app');
      await settle(tester);
      expect(find.text('Нажмите, чтобы повторить'), findsOneWidget);
      server.revision = 4;
      await tapRefresh(tester);
      expect(find.text('Нажмите, чтобы повторить'), findsNothing);
      expect(find.text('Нужно скачать · откроется после загрузки'), findsOneWidget);
    });

    testWidgets('the owner decision section keeps its header, count and unchanged meaning', (tester) async {
      final server = SyntheticServer(reviews: true);
      final bridge = fixture(tester, connection(), server.respond);
      await mountUx(tester, bridge);
      expect(find.text('Ждут вашего решения'), findsOneWidget);
      expect(find.text('Synthetic preview'), findsOneWidget);
      expect(find.text('изменение к ревизии 3 · предпросмотр'), findsOneWidget);
      expect(find.text('Ваши приложения'), findsOneWidget);
      expect(find.text('Synthetic app'), findsOneWidget);
    });

    test('avatar letter and colour are deterministic, theme-derived and emoji-safe', () {
      expect(AppAvatar.initial('  weather', 'w'), 'W');
      expect(AppAvatar.initial('', 'utilities'), 'U');
      expect(AppAvatar.initial('🌦 Погода', 'x'), '🌦');
      expect(AppAvatar.stableHash('utilities'), AppAvatar.stableHash('utilities'));
      expect(AppAvatar.stableHash('utilities'), isNot(AppAvatar.stableHash('weather')));
      final dark = ColorScheme.fromSeed(seedColor: const Color(0xFF8B5E34), brightness: Brightness.dark);
      final light = ColorScheme.fromSeed(seedColor: const Color(0xFF8B5E34));
      expect(AppAvatar.colors(dark, 'utilities'), AppAvatar.colors(dark, 'utilities'));
      expect(AppAvatar.colors(dark, 'utilities'), isNot(AppAvatar.colors(light, 'utilities')));
      final (background, foreground) = AppAvatar.colors(dark, 'utilities');
      expect(HSLColor.fromColor(background).lightness, lessThan(HSLColor.fromColor(foreground).lightness));
    });
  });

  group('pull to refresh', () {
    Future<void> pull(WidgetTester tester) async {
      await tester.drag(find.byType(ListView), const Offset(0, 320));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('pulling the list runs the existing guarded refresh exactly once', (tester) async {
      final bridge = fixture(tester, connection(), SyntheticServer().respond);
      await mountUx(tester, bridge);
      expect(bridge.count('/apps'), 1);
      expect(bridge.count('/devices/hello'), 1);
      await pull(tester);
      await settle(tester);
      await tester.pumpAndSettle();
      expect(bridge.count('/apps'), 2);
      expect(bridge.count('/devices/hello'), 2);
      expect(bridge.clients, hasLength(1), reason: 'no new transport or request path');
    });

    testWidgets('a pull while a refresh is in flight starts nothing new', (tester) async {
      final server = SyntheticServer();
      Completer<http.Response>? hold;
      final bridge = fixture(tester, connection(), (req, c) {
        final pending = hold;
        if (pending != null && req.url.path.endsWith('/apps')) return pending.future;
        return server.respond(req, c);
      });
      await mountUx(tester, bridge);
      hold = Completer<http.Response>();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Обновить'));
        for (var i = 0; i < 300 && bridge.count('/apps') < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      expect(bridge.count('/apps'), 2);
      expect(find.text('Обновляю…'), findsOneWidget);
      await pull(tester);
      expect(bridge.count('/apps'), 2);
      hold.complete(
        server.respond(http.Request('GET', Uri.parse('https://synthetic.invalid/tenant$apiPrefix/apps')), connection())
            as http.Response,
      );
      await settle(tester);
      await tester.pumpAndSettle();
      expect(bridge.count('/apps'), 2);
      expect(find.text('Онлайн'), findsOneWidget);
    });

    testWidgets('an unconfigured screen is not pullable and sends no request', (tester) async {
      final bridge = fixture(tester, null, (_, _) => throw StateError('No network expected'));
      await mountUx(tester, bridge, onConfigure: () {});
      expect(find.byType(RefreshIndicator), findsNothing);
      expect(find.byTooltip('Обновить'), findsNothing);
      expect(bridge.clients, isEmpty);
    });
  });

  group('first-time setup', () {
    testWidgets('one friendly card: short steps, ONE primary button, chat note; nothing is read or sent', (
      tester,
    ) async {
      final bridge = fixture(tester, null, (_, _) => throw StateError('No network expected'));
      var configure = 0;
      await mountUx(tester, bridge, onConfigure: () => configure++);
      expect(find.text('Не настроено'), findsOneWidget);
      expect(find.text('Surfaces не настроены'), findsOneWidget);
      expect(find.text('Попросите Hermes в чате или Telegram подключить приложение на телефоне.'), findsOneWidget);
      expect(find.text('Скопируйте строку, которую он пришлёт.'), findsOneWidget);
      expect(find.text('Нажмите «Вставить код подключения».'), findsOneWidget);
      expect(find.text('Чат работает и без настройки.'), findsOneWidget);
      expect(find.text('Настроить Surfaces'), findsOneWidget);
      expect(find.byTooltip('Настроить Surfaces'), findsOneWidget);
      expect(find.text('Настройки'), findsNothing, reason: 'no second settings control next to the primary button');
      expect(find.textContaining('Чат доступен в основном приложении'), findsNothing);
      await tester.tap(find.text('Настроить Surfaces'));
      expect(configure, 1);
      await tester.tap(find.text('Открыть чат'));
      await tester.pump();
      expect(bridge.chatCalls, 1);
      expect(bridge.clients, isEmpty);
      expect(bridge.supportReads, 0);
      expect(bridge.keyReads, 0);
    });

    testWidgets('a host that can paste leads with "paste connection code" and keeps manual setup second', (
      tester,
    ) async {
      final bridge = fixture(tester, null, (_, _) => throw StateError('No network expected'));
      var configure = 0;
      var paste = 0;
      await mountUx(tester, bridge, onConfigure: () => configure++, onPasteCode: () => paste++);
      final pasteButton = find.byKey(const ValueKey('apps-paste-code'));
      expect(pasteButton, findsOneWidget);
      expect(find.descendant(of: pasteButton, matching: find.text('Вставить код подключения')), findsOneWidget);
      expect(tester.widget(pasteButton), isA<FilledButton>());
      expect(find.widgetWithText(OutlinedButton, 'Настроить Surfaces'), findsOneWidget, reason: 'manual way, second');
      await tester.tap(pasteButton);
      expect(paste, 1);
      expect(configure, 0, reason: 'pasting does not open the manual form by itself');
      await tester.tap(find.text('Настроить Surfaces'));
      expect(configure, 1);
      expect(bridge.clients, isEmpty, reason: 'nothing is read or sent by showing the card');
    });

    testWidgets('without the paste hook the card is exactly as before', (tester) async {
      final bridge = fixture(tester, null, (_, _) => throw StateError('No network expected'));
      await mountUx(tester, bridge, onConfigure: () {});
      expect(find.byKey(const ValueKey('apps-paste-code')), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Настроить Surfaces'), findsOneWidget);
    });
  });

  group('how to create an app', () {
    const hint = 'Чтобы создать приложение, попросите Hermes в чате: «Сделай экран учёта трат за месяц».';
    const hintKey = ValueKey('apps-create-hint');

    Responder emptyCatalogue(SyntheticServer server) =>
        (req, c) => req.url.path.endsWith('/apps') ? jsonResponse({'apps': <Object>[]}) : server.respond(req, c);

    testWidgets('the list ends with ONE quiet hint that points at the existing chat action', (tester) async {
      final bridge = fixture(tester, connection(), SyntheticServer(reviews: true).respond);
      await mountUx(tester, bridge);
      expect(find.text(hint), findsOneWidget);
      final lastCard = tester.getBottomLeft(find.byType(ListTile).last).dy;
      expect(tester.getTopLeft(find.byKey(hintKey)).dy, greaterThan(lastCard), reason: 'at the END of the list');
      expect(find.text('Открыть чат'), findsOneWidget, reason: 'no second chat button');
      for (final type in [ButtonStyleButton, InkWell, IconButton]) {
        expect(
          find.descendant(of: find.byKey(hintKey), matching: find.byType(type)),
          findsNothing,
          reason: '$type',
        );
      }
      await tester.tap(find.text('Открыть чат'));
      expect(bridge.chatCalls, 1);
    });

    testWidgets('an empty catalogue says how to get the first app and starts no new request', (tester) async {
      final bridge = fixture(tester, connection(), emptyCatalogue(SyntheticServer()));
      await mountUx(tester, bridge);
      expect(find.text('Приложений нет'), findsOneWidget);
      expect(find.text('Когда Hermes опубликует мини-приложение, оно появится здесь.'), findsOneWidget);
      expect(find.text(hint), findsOneWidget);
      expect(find.text('Открыть чат'), findsOneWidget, reason: 'the header action is the only chat button');
      final paths = {for (final r in bridge.requests) r.url.path.substring('/tenant$apiPrefix'.length)};
      expect(paths, {'/devices/hello', '/apps', '/health'}, reason: 'the hint adds no request');
      expect(bridge.clients, hasLength(1));
    });

    testWidgets('the standalone page (own app bar) shows the same hint and one Open chat action', (tester) async {
      final bridge = fixture(tester, connection(), emptyCatalogue(SyntheticServer()));
      await mountUx(tester, bridge, embedded: false);
      expect(find.text(hint), findsOneWidget);
      expect(find.text('Открыть чат'), findsOneWidget);
    });

    testWidgets('states that are not a catalogue do not show it', (tester) async {
      final unconfigured = fixture(tester, null, (_, _) => throw StateError('No network expected'));
      await mountUx(tester, unconfigured, onConfigure: () {});
      expect(find.text('Surfaces не настроены'), findsOneWidget);
      expect(find.byKey(hintKey), findsNothing);
      final rejected = fixture(tester, connection(), (_, _) => jsonResponse({'error': 'synthetic'}, 401));
      await mountUx(tester, rejected, onConfigure: () {});
      expect(find.text('Нет доступа к Surfaces'), findsOneWidget);
      expect(find.byKey(hintKey), findsNothing);
      final broken = fixture(tester, connection(), (_, _) => jsonResponse({'error': 'synthetic'}, 500));
      await mountUx(tester, broken);
      expect(find.text('Не удалось загрузить приложения'), findsOneWidget);
      expect(find.byKey(hintKey), findsNothing);
    });
  });

  group('as a tab of the host', () {
    testWidgets('the header drops Open chat, and keeps refresh and settings', (tester) async {
      final bridge = fixture(tester, connection(), SyntheticServer().respond);
      await mountUx(tester, bridge, onConfigure: () {}, showChat: false);
      expect(find.text('Открыть чат'), findsNothing);
      expect(find.byTooltip('Обновить'), findsOneWidget);
      expect(find.byTooltip('Настроить Surfaces'), findsOneWidget);
      expect(find.byKey(chipKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Open chat stays by default, so every other host is unchanged', (tester) async {
      final bridge = fixture(tester, connection(), SyntheticServer().respond);
      await mountUx(tester, bridge, onConfigure: () {});
      expect(find.text('Открыть чат'), findsOneWidget);
    });

    testWidgets('an unconfigured tab shows its card and no buttons of the header', (tester) async {
      final bridge = fixture(tester, null, (_, _) => throw StateError('No network expected'));
      await mountUx(tester, bridge, showChat: false);
      expect(find.text('Открыть чат'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.text('Не настроено'), findsOneWidget);
    });

    testWidgets('the standalone page keeps its own Open chat whatever the flag says', (tester) async {
      final bridge = fixture(tester, connection(), SyntheticServer().respond);
      await mountUx(tester, bridge, embedded: false, showChat: false);
      expect(find.text('Открыть чат'), findsOneWidget);
    });

    testWidgets('a hidden tab polls nothing, and reads once, quietly, when it is shown again', (tester) async {
      final bridge = fixture(tester, connection(), SyntheticServer(reviews: true).respond);
      await mountUx(tester, bridge);

      // Control: on screen, the five-second tick re-reads the previews.
      final onScreen = bridge.count('/previews');
      await tester.pump(const Duration(seconds: 5));
      expect(bridge.count('/previews'), greaterThan(onScreen), reason: 'the poll runs while the tab is visible');

      await mountUx(tester, bridge, active: false);
      final previews = bridge.count('/previews');
      final catalogue = bridge.count('/apps');
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      expect(bridge.count('/previews'), previews, reason: 'nothing is polled while the tab is hidden');
      expect(bridge.count('/apps'), catalogue);

      await mountUx(tester, bridge, active: true);
      for (var i = 0; i < 300 && bridge.count('/apps') < catalogue + 1; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(bridge.count('/apps'), catalogue + 1, reason: 'one read the moment the tab is shown again');
      expect(find.byType(LinearProgressIndicator), findsNothing, reason: 'quiet: no busy bar, no disabled cards');
    });
  });

  group('narrow width and large text', () {
    final scenarios = <String, Future<FakeBridge> Function(WidgetTester)>{
      'catalogue with previews and review status': (tester) async {
        final bridge = fixture(tester, connection(), SyntheticServer(reviews: true).respond);
        return bridge;
      },
      'first-time setup': (tester) async => fixture(tester, null, (_, _) => throw StateError('No network expected')),
      'rejected token': (tester) async =>
          fixture(tester, connection(), (_, _) => jsonResponse({'error': 'Synthetic rejected credential'}, 401)),
      'offline without cache': (tester) async =>
          fixture(tester, connection(), (_, _) => throw http.ClientException('Synthetic offline')),
    };
    for (final entry in scenarios.entries) {
      testWidgets('320dp at 1.3x text scale: ${entry.key}', (tester) async {
        phone(tester, width: 320, height: 640);
        final bridge = await entry.value(tester);
        await mountUx(tester, bridge, onConfigure: () {}, textScale: 1.3);
        expect(tester.takeException(), isNull);
        expect(find.byKey(chipKey), findsOneWidget);
        expect(find.text('Открыть чат'), findsOneWidget);
      });
    }

    testWidgets('320dp at 1.3x text scale: the create-app hint wraps below the list and below the empty card', (
      tester,
    ) async {
      phone(tester, width: 320, height: 640);
      const hintKey = ValueKey('apps-create-hint');
      final server = SyntheticServer(reviews: true);
      final bridge = fixture(tester, connection(), server.respond);
      await mountUx(tester, bridge, onConfigure: () {}, textScale: 1.3);
      await tester.scrollUntilVisible(find.byKey(hintKey), 120, scrollable: find.byType(Scrollable).first);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(hintKey)).width, lessThanOrEqualTo(320));
      expect(tester.getTopLeft(find.byKey(hintKey)).dx, greaterThanOrEqualTo(0));

      final empty = fixture(
        tester,
        connection(),
        (req, c) => req.url.path.endsWith('/apps') ? jsonResponse({'apps': <Object>[]}) : server.respond(req, c),
      );
      await mountUx(tester, empty, onConfigure: () {}, textScale: 1.3);
      await tester.scrollUntilVisible(find.byKey(hintKey), 120, scrollable: find.byType(Scrollable).first);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(hintKey)).width, lessThanOrEqualTo(320));
    });

    testWidgets('320dp at 1.3x text scale: a long host notice wraps', (tester) async {
      phone(tester, width: 320, height: 640);
      final bridge = fixture(tester, null, (_, _) => throw StateError('No network expected'));
      await mountUx(tester, bridge, onConfigure: () {}, textScale: 1.3, hostNotice: SurfacesText.noticeContextMismatch);
      expect(tester.takeException(), isNull);
    });
  });
}
