import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:http/http.dart' as http;

import 'native_association_support.dart';
import 'support.dart';

/// Language of the Apps UI: English is the source and the fallback, Russian the second complete
/// language. Everything else in the suite runs under an explicit Locale('ru').
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpModule(
    WidgetTester tester,
    FakeBridge bridge,
    Locale locale, {
    VoidCallback? onConfigure,
    SurfacesText? hostNotice,
  }) async {
    await tester.pumpWidget(
      localizedApp(
        locale: locale,
        home: Scaffold(
          body: AppsModule(
            bridge: bridge,
            embedded: true,
            onConfigure: onConfigure,
            hostNotice: hostNotice,
            autoSync: false,
            surfacePageBuilder: (_, request) => FakePage(request: request),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  FakeBridge bridgeFor(WidgetTester tester, SurfacesConnection? c, Responder respond) {
    final root = Directory.systemTemp.createTempSync('hermes_bridge_locale_');
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

  group('Apps screen', () {
    for (final language in ['en', 'de', 'zz']) {
      testWidgets('first-time setup is English for `$language` (source and fallback language)', (tester) async {
        final bridge = bridgeFor(tester, null, (_, _) => throw StateError('No network expected'));
        await pumpModule(tester, bridge, Locale(language), onConfigure: () {});
        expect(find.text('Not set up'), findsOneWidget);
        expect(find.text('Surfaces is not set up'), findsOneWidget);
        expect(find.text('Ask Hermes in chat or Telegram to connect the phone app.'), findsOneWidget);
        expect(find.text('Chat works without this setup.'), findsOneWidget);
        expect(find.text('Set up Surfaces'), findsOneWidget);
        expect(find.text('Open chat'), findsOneWidget);
        expect(find.textContaining('Не настроено'), findsNothing);
      });
    }

    testWidgets('first-time setup is Russian for `ru`', (tester) async {
      final bridge = bridgeFor(tester, null, (_, _) => throw StateError('No network expected'));
      await pumpModule(tester, bridge, const Locale('ru'), onConfigure: () {});
      expect(find.text('Не настроено'), findsOneWidget);
      expect(find.text('Surfaces не настроены'), findsOneWidget);
      expect(find.text('Настроить Surfaces'), findsOneWidget);
      expect(find.text('Открыть чат'), findsOneWidget);
      expect(find.text('Set up Surfaces'), findsNothing);
    });

    testWidgets('catalogue states, subtitles and a placeholder-filled chip are English', (tester) async {
      final server = SyntheticServer(reviews: true);
      var down = false;
      final bridge = bridgeFor(tester, connection(), (req, c) {
        if (down) throw http.ClientException('Synthetic offline');
        return server.respond(req, c);
      });
      await pumpModule(tester, bridge, const Locale('en'));
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Waiting for your decision'), findsOneWidget);
      expect(find.text('change to revision 3 · preview'), findsOneWidget);
      expect(find.text('Your apps'), findsOneWidget);
      expect(find.text('Needs download · opens after loading'), findsOneWidget);
      expect(find.textContaining('Approval is disabled'), findsOneWidget);
      down = true;
      await tester.runAsync(() => tester.tap(find.byTooltip('Refresh')));
      await settle(tester);
      expect(find.textContaining(RegExp(r'^Offline')), findsOneWidget);
      expect(find.textContaining('{'), findsNothing, reason: 'no placeholder is left open');
    });

    const enHint = 'To create an app, ask Hermes in chat, for example: “Make a monthly expenses screen”.';
    for (final entry in const {
      'en': enHint,
      'de': enHint,
      'zz': enHint,
      'ru': 'Чтобы создать приложение, попросите Hermes в чате: «Сделай экран учёта трат за месяц».',
    }.entries) {
      testWidgets('how to create an app is explained under the list and in the empty state for `${entry.key}`', (
        tester,
      ) async {
        final server = SyntheticServer();
        var empty = false;
        final bridge = bridgeFor(
          tester,
          connection(),
          (req, c) =>
              empty && req.url.path.endsWith('/apps') ? jsonResponse({'apps': <Object>[]}) : server.respond(req, c),
        );
        await pumpModule(tester, bridge, Locale(entry.key));
        expect(find.text('Synthetic app'), findsOneWidget);
        expect(find.text(entry.value), findsOneWidget);
        empty = true;
        await tester.runAsync(() => tester.tap(find.byTooltip(entry.key == 'ru' ? 'Обновить' : 'Refresh')));
        await settle(tester);
        expect(find.text('Synthetic app'), findsNothing);
        expect(find.text(entry.value), findsOneWidget);
      });
    }

    testWidgets('a rejected token and an invalid address are English and echo nothing', (tester) async {
      final unauthorized = bridgeFor(
        tester,
        connection(),
        (_, _) => jsonResponse({'error': 'raw synthetic-detail'}, 401),
      );
      await pumpModule(tester, unauthorized, const Locale('en'), onConfigure: () {});
      expect(find.text('The server rejected the token'), findsOneWidget);
      expect(find.text('No access to Surfaces'), findsOneWidget);
      expect(find.text('Set up Surfaces'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.textContaining('synthetic-detail'), findsNothing);
    });

    testWidgets('every host notice has a localized text in every registered language', (tester) async {
      for (final language in SurfacesStrings.languages) {
        final strings = SurfacesStrings.forLanguage(language);
        for (final notice in NativeAssociationNotice.values) {
          expect(strings(notice.text), isNotEmpty, reason: '$language/$notice');
        }
      }
      final bridge = bridgeFor(tester, null, (_, _) => throw StateError('No network expected'));
      await pumpModule(tester, bridge, const Locale('en'), hostNotice: NativeAssociationNotice.contextMismatch.text);
      expect(find.text('The chat context differs from the saved connection. Open the apps again.'), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
    });

    testWidgets('the controller keeps an English diagnostic mirror and a language-free code', (tester) async {
      final h = NativeHarness();
      addTearDown(h.dispose);
      final c = h.make();
      await tester.runAsync(flushNative);
      expect(c.notice.value, NativeAssociationNotice.unconfigured);
      expect(c.status.value, 'Surfaces is not set up for the selected connection. Chat is available.');
    });
  });

  group('configuration dialog', () {
    Future<NativeAssociationController> open(
      WidgetTester tester,
      NativeHarness h,
      Locale locale, {
      String? suggested,
    }) async {
      final c = h.make();
      await tester.runAsync(flushNative);
      await tester.pumpWidget(
        localizedApp(
          locale: locale,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showNativeAssociationDialog(
                  context,
                  controller: c,
                  legacyPrefill: () async => null,
                  suggestedUrl: suggested,
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('English: fields, helper text, validation, confirmation and check verdict', (tester) async {
      final h = NativeHarness()..seed();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        h.dispose();
      });
      h.client = (connection) {
        final client = FakeClient(connection, h.server.respond);
        h.clients.add(client);
        return client;
      };
      await open(tester, h, const Locale('en'));
      expect(find.text('Set up Surfaces'), findsOneWidget);
      expect(find.text('Surfaces address (HTTP/S)'), findsOneWidget);
      expect(find.text('Separate Surfaces token (bearer)'), findsOneWidget);
      expect(find.text('Device ID of this phone'), findsOneWidget);
      expect(find.text('Fill in from previous settings…'), findsOneWidget);
      expect(find.byTooltip('Show token'), findsOneWidget);
      expect(find.textContaining('Profile: “synthetic_profile”'), findsOneWidget);
      await tester.ensureVisible(find.text('Check connection'));
      await tester.tap(find.text('Check connection'));
      await tester.pump();
      await tester.runAsync(flushNative);
      await tester.pumpAndSettle();
      expect(find.text('The server responds'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('surfaces-device')), 'Pixel 7');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Device ID: 1–64 characters'), findsWidgets);
      await tester.enterText(find.byKey(const ValueKey('surfaces-device')), 'device_ok');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Save the Surfaces binding?'), findsOneWidget);
      expect(find.text('Confirm saving'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.writes, isEmpty);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    });

    for (final entry in const {
      'en': 'Use the chat server address',
      'de': 'Use the chat server address',
      'ru': 'Подставить адрес с сервера чата',
    }.entries) {
      testWidgets('the chat-address button reads `${entry.value}` for `${entry.key}`', (tester) async {
        final h = NativeHarness(); // Unconfigured: the field is empty, so the proposal is offered.
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          h.dispose();
        });
        await open(tester, h, Locale(entry.key), suggested: 'https://synthetic.invalid/tenant/ms');
        expect(find.text(entry.value), findsOneWidget);
        expect(find.textContaining('synthetic.invalid/tenant/ms'), findsNothing, reason: 'the label never echoes it');
        await tester.ensureVisible(find.text(entry.value));
        await tester.tap(find.text(entry.value));
        await tester.pumpAndSettle();
        final url = tester.widget<TextField>(find.byKey(const ValueKey('surfaces-url')));
        expect(url.controller!.text, 'https://synthetic.invalid/tenant/ms');
        expect(find.text(entry.value), findsNothing);
      });
    }

    testWidgets('Russian keeps the exact wording the host integration tests assert', (tester) async {
      final h = NativeHarness()..seed();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        h.dispose();
      });
      await open(tester, h, const Locale('ru'));
      for (final text in [
        'Настроить Surfaces',
        'Сохранить',
        'Закрыть',
        'Заполнить из прежних настроек…',
        'Проверить подключение',
      ]) {
        await tester.ensureVisible(find.text(text));
        expect(find.text(text), findsOneWidget, reason: text);
      }
      await tester.ensureVisible(find.text('Заполнить из прежних настроек…'));
      await tester.tap(find.text('Заполнить из прежних настроек…'));
      await tester.pumpAndSettle();
      expect(find.text('Прочитать'), findsOneWidget);
      expect(find.text('Отмена'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
    });
  });

  group('no hardcoded user text', () {
    // Only the string layer may hold human-language literals; comments are free to explain.
    final cyrillic = RegExp('[А-Яа-яЁё]');

    List<String> offenders(String directory, {Set<String> except = const {}}) {
      final found = <String>[];
      for (final entity in Directory(directory).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final name = entity.uri.pathSegments.last;
        if (except.contains(name)) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].trimLeft();
          if (code.startsWith('//') || code.startsWith('*')) continue;
          if (cyrillic.hasMatch(code)) found.add('$name:${i + 1}: ${code.trim()}');
        }
      }
      return found;
    }

    test('the bridge library holds no Cyrillic string literal', () {
      expect(offenders('lib'), isEmpty);
    });

    test('the core library holds none outside the string layer', () {
      expect(offenders('../hermes_surfaces/lib', except: {'strings.dart'}), isEmpty);
    });

    test('every key of the string layer is used by the bridge or core library', () {
      final source = StringBuffer();
      for (final directory in ['lib', '../hermes_surfaces/lib']) {
        for (final entity in Directory(directory).listSync(recursive: true)) {
          if (entity is File && entity.path.endsWith('.dart') && !entity.path.endsWith('strings.dart')) {
            source.writeln(entity.readAsStringSync());
          }
        }
      }
      final text = source.toString();
      const hostNavigation = {SurfacesText.appsPageTitle, SurfacesText.appsEntrySubtitle};
      final unused = [
        for (final key in SurfacesText.values)
          // The two host-navigation keys are read by the host application's own menu and page title.
          if (!text.contains('SurfacesText.${key.name}') && !hostNavigation.contains(key)) key.name,
      ];
      expect(unused, isEmpty, reason: 'dead keys: remove them or use them');
    });
  });
}
