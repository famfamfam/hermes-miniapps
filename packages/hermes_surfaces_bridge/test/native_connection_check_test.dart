import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:http/http.dart' as http;

import 'native_association_support.dart';
import 'support.dart';

/// The explicit "Проверить подключение" action and the dialog's presentation. Everything here is
/// synthetic: no real server, token or storage. Saving/lease/legacy behaviour stays in
/// native_association_dialog_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<NativeHarness> setup(WidgetTester tester, {bool configured = true}) async {
    final h = NativeHarness();
    if (configured) h.seed();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      h.dispose();
    });
    return h;
  }

  /// Every `client` the controller asks the host for answers with [respond] and is recorded.
  void answer(NativeHarness h, Responder respond) {
    h.client = (connection) {
      final client = FakeClient(connection, respond);
      h.clients.add(client);
      return client;
    };
  }

  Future<void> mountDialog(WidgetTester tester, NativeAssociationController controller, {double scale = 1.0}) async {
    await tester.runAsync(flushNative);
    await tester.pumpWidget(
      localizedApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNativeAssociationDialog(context, controller: controller),
              child: const Text('Configure synthetic association'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Configure synthetic association'));
    await tester.pumpAndSettle();
  }

  TextField field(WidgetTester tester, String id) => tester.widget<TextField>(find.byKey(ValueKey('surfaces-$id')));

  Future<void> fill(WidgetTester tester) async {
    await tester.enterText(find.byKey(const ValueKey('surfaces-url')), 'https://synthetic.invalid/tenant');
    await tester.enterText(find.byKey(const ValueKey('surfaces-bearer')), 'typed_separate_bearer');
    await tester.enterText(find.byKey(const ValueKey('surfaces-device')), 'typed_explicit_device');
  }

  /// Text widgets only: the fields' own editable text legitimately holds what the user typed.
  String shownText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
      .join('\n');

  Finder checkButton() => find.text('Проверить подключение');

  Future<void> tapCheck(WidgetTester tester, {bool settle = true}) async {
    await tester.ensureVisible(checkButton());
    await tester.tap(checkButton());
    await tester.pump();
    await tester.runAsync(flushNative);
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  group('explicit connection check from the dialog', () {
    testWidgets('one read-only health request with the typed values; client closed; nothing saved or bound', (
      tester,
    ) async {
      final h = await setup(tester);
      answer(h, h.server.respond);
      final c = h.make();
      await mountDialog(tester, c);
      expect(h.clients, isEmpty, reason: 'opening the dialog sends nothing');
      expect(find.text('Сервер отвечает'), findsNothing);
      await fill(tester);
      final status = c.status.value;
      await tapCheck(tester);
      final client = h.clients.single;
      final request = client.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/tenant$apiPrefix/health');
      expect(request.headers['Authorization'], 'Bearer typed_separate_bearer');
      expect(request.headers['X-Device-Id'], 'typed_explicit_device');
      expect(request.followRedirects, isFalse);
      expect(client.closes, 1);
      expect(find.text('Сервер отвечает'), findsOneWidget);
      expect(h.writes, isEmpty);
      expect(c.activeConnection.value, isNull, reason: 'a check never binds Apps');
      expect(c.status.value, status);
      expect(h.keyReads, 0);
      expect(h.supportReads, 0);
      expect(shownText(tester), isNot(contains('typed_separate_bearer')));
      // Closing keeps exactly the previously saved association.
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      await tester.runAsync(flushNative);
      expect(h.writes, isEmpty);
      expect(c.activeConnection.value!.config.token, 'synthetic_surfaces_bearer');
    });

    testWidgets('401 says the token is wrong and shows no body, token or address', (tester) async {
      final h = await setup(tester);
      answer(h, (_, _) => jsonResponse({'error': 'raw body synthetic-secret-detail'}, 401));
      final c = h.make();
      await mountDialog(tester, c);
      await fill(tester);
      await tapCheck(tester);
      expect(find.text('Неверный токен'), findsOneWidget);
      expect(find.text('Сервер отвечает'), findsNothing);
      final shown = shownText(tester);
      for (final secret in ['synthetic-secret-detail', 'typed_separate_bearer', 'synthetic.invalid']) {
        expect(shown, isNot(contains(secret)));
      }
      expect(h.clients.single.requests, hasLength(1));
      expect(h.clients.single.closes, 1);
      expect(h.writes, isEmpty);
      expect(c.activeConnection.value, isNull);
    });

    final unreachable = <String, Responder>{
      'network failure': (_, _) => throw http.ClientException('raw-synthetic-network-detail https://synthetic.invalid'),
      'captive portal 200': (_, _) => http.Response('<html>synthetic-portal-body</html>', 200),
      'server error': (_, _) => jsonResponse({'error': 'synthetic-500-body'}, 500),
      'redirect': (_, _) => http.Response('', 302, headers: {'location': 'https://other.invalid/synthetic-hop'}),
      'JSON that is not an object': (_, _) => jsonResponse(['synthetic-list-body']),
    };
    for (final entry in unreachable.entries) {
      testWidgets('${entry.key} is "Сервер недоступен", with no detail echoed', (tester) async {
        final h = await setup(tester);
        answer(h, entry.value);
        final c = h.make();
        await mountDialog(tester, c);
        await fill(tester);
        await tapCheck(tester);
        expect(find.text('Сервер недоступен'), findsOneWidget);
        final shown = shownText(tester);
        for (final secret in ['synthetic-', 'raw-synthetic', 'other.invalid', 'typed_separate_bearer']) {
          expect(shown, isNot(contains(secret)));
        }
        expect(h.clients.single.requests, hasLength(1));
        expect(h.clients.single.closes, 1);
        expect(h.writes, isEmpty);
        expect(c.activeConnection.value, isNull);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('invalid fields are explained before any client is created', (tester) async {
      final h = await setup(tester);
      answer(h, h.server.respond);
      final c = h.make();
      await mountDialog(tester, c);
      await fill(tester);
      await tester.enterText(find.byKey(const ValueKey('surfaces-device')), 'Pixel 7');
      await tapCheck(tester);
      expect(find.textContaining('Идентификатор устройства'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('surfaces-device')), 'device_ok');
      await tester.enterText(find.byKey(const ValueKey('surfaces-url')), 'https://user:topsecret@synthetic.invalid/t');
      await tapCheck(tester);
      expect(find.text('Проверьте поля'), findsOneWidget);
      expect(shownText(tester), isNot(contains('topsecret')));
      await tester.enterText(find.byKey(const ValueKey('surfaces-url')), 'https://synthetic.invalid/t');
      await tester.enterText(find.byKey(const ValueKey('surfaces-bearer')), '   ');
      await tapCheck(tester);
      expect(find.text('Проверьте поля'), findsOneWidget);
      expect(h.clients, isEmpty);
      expect(h.writes, isEmpty);
    });

    testWidgets('a second tap while checking sends nothing; the result is dropped once a field is edited', (
      tester,
    ) async {
      final h = await setup(tester);
      final held = Completer<http.Response>();
      answer(h, (_, _) => held.future);
      final c = h.make();
      await mountDialog(tester, c);
      await fill(tester);
      await tapCheck(tester, settle: false);
      expect(find.text('Проверяю…'), findsOneWidget);
      final button = find.ancestor(of: checkButton(), matching: find.byWidgetPredicate((w) => w is OutlinedButton));
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      await tester.tap(checkButton(), warnIfMissed: false);
      await tester.pump();
      held.complete(jsonResponse({'reviews': false, 'approverPaired': true}));
      await tester.runAsync(flushNative);
      await tester.pumpAndSettle();
      expect(h.clients.single.requests, hasLength(1));
      expect(find.text('Сервер отвечает'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('surfaces-device')), 'another_device');
      await tester.pump();
      expect(find.text('Сервер отвечает'), findsNothing, reason: 'the verdict belongs to the values that were checked');
    });

    testWidgets('a target change during the request discards the verdict, clears fields and never writes', (
      tester,
    ) async {
      final h = await setup(tester);
      final held = Completer<http.Response>();
      answer(h, (_, _) => held.future);
      final c = h.make();
      await mountDialog(tester, c);
      await fill(tester);
      await tapCheck(tester, settle: false);
      expect(h.clients.single.requests, hasLength(1));
      h.target.select(nativeOwner(id: 'B'));
      h.target.select(h.owner);
      held.complete(jsonResponse({'reviews': false, 'approverPaired': true}));
      await tester.runAsync(flushNative);
      await tester.pumpAndSettle();
      expect(find.text('Сервер отвечает'), findsNothing);
      expect(find.textContaining('Подключение изменилось'), findsOneWidget);
      expect(field(tester, 'bearer').controller!.text, isEmpty);
      expect(field(tester, 'url').controller!.text, isEmpty);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Сохранить')).onPressed, isNull);
      expect(h.clients.single.closes, 1);
      expect(h.writes, isEmpty);
      expect(c.activeConnection.value, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('closing the dialog mid-request closes the client and throws nothing', (tester) async {
      final h = await setup(tester);
      final held = Completer<http.Response>();
      answer(h, (_, _) => held.future);
      final c = h.make();
      await mountDialog(tester, c);
      await fill(tester);
      await tapCheck(tester, settle: false);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      held.complete(jsonResponse({'reviews': false}));
      await tester.runAsync(flushNative);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(h.clients.single.closes, 1);
      expect(h.writes, isEmpty);
    });
  });

  group('controller.checkConnection', () {
    NativeAssociationSettings typed({
      String bearer = 'typed_separate_bearer',
      String url = 'https://synthetic.invalid/tenant',
    }) => nativeSettings(url: url, bearer: bearer, device: 'typed_device');

    test('a shared client is refused and never closed; a fresh one is closed', () async {
      final h = NativeHarness()..seed();
      addTearDown(h.dispose);
      final shared = FakeClient(connection(), h.server.respond);
      h.client = (_) => shared;
      final c = h.make();
      await flushNative();
      final configuration = c.beginConfiguration();
      expect(await c.checkConnection(configuration, typed()), NativeConnectionCheck.reachable);
      expect(shared.closes, 1, reason: 'the first call owned a fresh client');
      expect(await c.checkConnection(configuration, typed()), NativeConnectionCheck.unreachable);
      expect(shared.closes, 1, reason: 'a reused client is not Apps-owned, so it is not closed again');
      expect(shared.requests, hasLength(1));
    });

    test('the timeout is bounded and a hung server ends as unreachable with the client closed', () async {
      final h = NativeHarness()..seed();
      addTearDown(h.dispose);
      final hung = Completer<http.Response>();
      answer(h, (_, _) => hung.future);
      final c = h.make();
      await flushNative();
      final configuration = c.beginConfiguration();
      final watch = Stopwatch()..start();
      final result = await c.checkConnection(configuration, typed(), timeout: const Duration(milliseconds: 80));
      expect(result, NativeConnectionCheck.unreachable);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(h.clients.single.closes, 1);
    });

    test('a failing client factory is unreachable without leaking its message', () async {
      final h = NativeHarness()..seed();
      addTearDown(h.dispose);
      h.client = (_) => throw StateError('raw-synthetic-secret');
      final c = h.make();
      await flushNative();
      final configuration = c.beginConfiguration();
      expect(await c.checkConnection(configuration, typed()), NativeConnectionCheck.unreachable);
    });

    test('invalid settings and a revoked configuration never create a client', () async {
      final h = NativeHarness()..seed();
      addTearDown(h.dispose);
      answer(h, h.server.respond);
      final c = h.make();
      await flushNative();
      final configuration = c.beginConfiguration();
      expect(await c.checkConnection(configuration, typed(bearer: '  ')), NativeConnectionCheck.invalid);
      expect(
        await c.checkConnection(configuration, typed(url: 'https://user:pw@synthetic.invalid/t')),
        NativeConnectionCheck.invalid,
      );
      expect(
        await c.checkConnection(configuration, typed(url: 'ftp://synthetic.invalid/t')),
        NativeConnectionCheck.invalid,
      );
      expect(h.clients, isEmpty);
      h.target.select(nativeOwner(id: 'B'));
      expect(await c.checkConnection(configuration, typed()), NativeConnectionCheck.stale);
      expect(h.clients, isEmpty);
    });

    test('it touches no storage and leaves the sanitised status and binding alone', () async {
      final h = NativeHarness();
      addTearDown(h.dispose);
      answer(h, h.server.respond);
      final c = h.make();
      await flushNative();
      final status = c.status.value;
      expect(c.notice.value, NativeAssociationNotice.unconfigured);
      final reads = h.reads.length;
      final configuration = c.beginConfiguration();
      expect(await c.checkConnection(configuration, typed()), NativeConnectionCheck.reachable);
      expect(h.reads.length, reads);
      expect(h.writes, isEmpty);
      expect(h.keyReads, 0);
      expect(h.supportReads, 0);
      expect(c.status.value, status);
      expect(c.notice.value, NativeAssociationNotice.unconfigured);
      expect(c.activeConnection.value, isNull);
    });
  });

  group('unconfigured hint', () {
    test('is true only after a fresh read found no association, and any other message clears it', () async {
      final h = NativeHarness();
      addTearDown(h.dispose);
      final c = h.make();
      await flushNative();
      expect(c.notice.value, NativeAssociationNotice.unconfigured);
      expect(c.status.value, contains('not set up'), reason: 'the status mirror is English diagnostics');
      final operation = h.mutations.begin();
      expect(c.notice.value, isNot(NativeAssociationNotice.unconfigured));
      expect(c.notice.value, NativeAssociationNotice.settingsChanging);
      operation.finish(success: true);
      await flushNative();
      expect(c.notice.value, NativeAssociationNotice.unconfigured, reason: 'a fresh exact read finds the same absence');
      final configuration = c.beginConfiguration();
      expect(await c.saveConfiguration(configuration, nativeSettings()), NativeAssociationSaveResult.saved);
      await flushNative();
      expect(c.notice.value, isNot(NativeAssociationNotice.unconfigured));
      expect(c.activeConnection.value, isNull, reason: 'nothing binds while the configuration is open');
      c.endConfiguration(configuration);
      await flushNative();
      expect(c.activeConnection.value, isNotNull);
      expect(c.notice.value, isNot(NativeAssociationNotice.unconfigured));
    });

    test('a seeded owner is never unconfigured', () async {
      final h = NativeHarness()..seed();
      addTearDown(h.dispose);
      final c = h.make();
      await flushNative();
      expect(c.notice.value, isNot(NativeAssociationNotice.unconfigured));
      expect(c.status.value, isNull);
    });
  });

  group('dialog presentation', () {
    testWidgets('the bearer is masked by default, can be shown on request and is masked again', (tester) async {
      final h = await setup(tester);
      final c = h.make();
      await mountDialog(tester, c);
      expect(field(tester, 'bearer').obscureText, isTrue);
      expect(find.byTooltip('Показать токен'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Показать токен'));
      await tester.tap(find.byTooltip('Показать токен'));
      await tester.pump();
      expect(field(tester, 'bearer').obscureText, isFalse);
      expect(field(tester, 'bearer').enableSuggestions, isFalse);
      await tester.tap(find.byTooltip('Скрыть токен'));
      await tester.pump();
      expect(field(tester, 'bearer').obscureText, isTrue);
      expect(h.writes, isEmpty);
    });

    testWidgets('fields are grouped with helper text and the keys the host tests rely on', (tester) async {
      final h = await setup(tester);
      final c = h.make();
      await mountDialog(tester, c);
      for (final label in ['Подключение', 'Безопасность страниц', 'Проверка']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.textContaining('на котором работает плагин Surfaces'), findsOneWidget);
      expect(find.textContaining('не Gateway API key'), findsOneWidget);
      expect(find.textContaining('1–64 символа'), findsOneWidget);
      expect(find.text('Сохранить'), findsOneWidget);
      expect(find.text('Закрыть'), findsOneWidget);
      expect(find.byKey(const ValueKey('surfaces-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('surfaces-bearer')), findsOneWidget);
      expect(find.byKey(const ValueKey('surfaces-device')), findsOneWidget);
    });

    testWidgets('320dp at 1.3x text scale does not overflow, including a long check verdict', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final h = await setup(tester);
      answer(h, (_, _) => jsonResponse({'error': 'rejected'}, 401));
      final c = h.make();
      await mountDialog(tester, c, scale: 1.3);
      await fill(tester);
      await tapCheck(tester);
      expect(find.text('Неверный токен'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byTooltip('Показать токен'));
      await tester.tap(find.byTooltip('Показать токен'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
