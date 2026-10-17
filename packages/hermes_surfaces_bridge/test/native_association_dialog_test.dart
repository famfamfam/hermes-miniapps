import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:http/http.dart' as http;

import 'native_association_support.dart';
import 'support.dart';

/// Mimics a native Workspace that owns and disposes its controller in State.dispose.
class _DisposingHost extends StatefulWidget {
  const _DisposingHost({required this.controller, required this.child});
  final NativeAssociationController controller;
  final Widget child;
  @override
  State<_DisposingHost> createState() => _DisposingHostState();
}

class _DisposingHostState extends State<_DisposingHost> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void main() {
  Future<NativeHarness> setup(WidgetTester tester, {bool configured = true}) async {
    final h = NativeHarness();
    if (configured) h.seed();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      h.dispose();
    });
    return h;
  }

  Future<void> mountDialog(
    WidgetTester tester,
    NativeAssociationController controller, {
    Future<NativeAssociationSettings?> Function()? legacy,
    String? suggested,
    double textScale = 1.0,
  }) async {
    await tester.runAsync(flushNative);
    await tester.pumpWidget(
      localizedApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNativeAssociationDialog(
                context,
                controller: controller,
                legacyPrefill: legacy,
                suggestedUrl: suggested,
              ),
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

  Future<void> confirmSave(WidgetTester tester) async {
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Сохранить привязку Surfaces?'), findsOneWidget);
    await tester.tap(find.text('Подтвердить сохранение'));
    await tester.pump();
    await tester.runAsync(flushNative);
    await tester.pumpAndSettle();
  }

  testWidgets('a device id the server would reject is refused before any confirmation or write', (tester) async {
    final h = await setup(tester);
    final c = h.make();
    await mountDialog(tester, c);
    await fill(tester);
    await tester.enterText(find.byKey(const ValueKey('surfaces-device')), 'Pixel 7');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Идентификатор устройства'), findsOneWidget);
    expect(find.text('Сохранить привязку Surfaces?'), findsNothing);
    expect(h.writes, isEmpty);
  });

  testWidgets('normal native open/cancel reads zero legacy tokens, masks bearer and disposes fields', (tester) async {
    final h = await setup(tester);
    final c = h.make();
    var legacyCalls = 0;
    await mountDialog(
      tester,
      c,
      legacy: () async {
        legacyCalls++;
        return nativeSettings();
      },
    );
    expect(legacyCalls, 0);
    expect(find.textContaining('Synthetic connection'), findsOneWidget);
    expect(find.textContaining('synthetic_profile'), findsOneWidget);
    expect(field(tester, 'bearer').obscureText, isTrue);
    expect(field(tester, 'bearer').enableSuggestions, isFalse);
    expect(field(tester, 'bearer').enableIMEPersonalizedLearning, isFalse);
    final texts = ['url', 'bearer', 'device'].map((id) => field(tester, id).controller!).toList();
    expect(texts[1].text, 'synthetic_surfaces_bearer');
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    await tester.runAsync(flushNative);
    expect(legacyCalls, 0);
    expect(h.writes, isEmpty);
    expect(h.keyReads, 0);
    expect(h.supportReads, 0);
    expect(c.activeConnection.value, isNotNull);
    for (final text in texts) {
      expect(() => text.addListener(() {}), throwsFlutterError);
    }
  });

  testWidgets('missing association has blank device, explicit native confirmation saves dedicated fields', (
    tester,
  ) async {
    final h = await setup(tester, configured: false);
    final c = h.make();
    var legacyCalls = 0;
    await mountDialog(
      tester,
      c,
      legacy: () async {
        legacyCalls++;
        return nativeSettings();
      },
    );
    expect(field(tester, 'device').controller!.text, isEmpty);
    expect(field(tester, 'bearer').controller!.text, isEmpty);
    await fill(tester);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(h.writes, isEmpty);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(h.writes, isEmpty);
    await confirmSave(tester);
    expect(find.byType(NativeAssociationDialog), findsNothing);
    expect(legacyCalls, 0);
    expect(h.writes.length, 1);
    expect(c.activeConnection.value!.config.token, 'typed_separate_bearer');
    expect(c.activeConnection.value!.config.deviceId, 'typed_explicit_device');
    expect(h.keyReads, 0);
  });

  testWidgets('legacy prefill only after separate consent; save still requires native owner confirmation', (
    tester,
  ) async {
    final h = await setup(tester, configured: false);
    final c = h.make();
    var calls = 0;
    await mountDialog(
      tester,
      c,
      legacy: () async {
        calls++;
        return nativeSettings(bearer: 'explicit_legacy_surfaces_only', device: 'explicit_legacy_device');
      },
    );
    await tester.ensureVisible(find.text('Заполнить из прежних настроек…'));
    await tester.tap(find.text('Заполнить из прежних настроек…'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.tap(find.text('Заполнить из прежних настроек…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Прочитать'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(field(tester, 'bearer').controller!.text, 'explicit_legacy_surfaces_only');
    expect(field(tester, 'device').controller!.text, 'explicit_legacy_device');
    expect(h.writes, isEmpty);
    await confirmSave(tester);
    expect(calls, 1);
    expect(h.writes.single.$2, contains('explicit_legacy_surfaces_only'));
    expect(h.supportReads, 0);
    expect(h.keyReads, 0);
  });

  testWidgets('same-frame A-B-A during consent never invokes legacy callback', (tester) async {
    final h = await setup(tester);
    final c = h.make();
    var calls = 0;
    await mountDialog(
      tester,
      c,
      legacy: () async {
        calls++;
        return nativeSettings();
      },
    );
    await tester.ensureVisible(find.text('Заполнить из прежних настроек…'));
    await tester.tap(find.text('Заполнить из прежних настроек…'));
    await tester.pumpAndSettle();
    h.target.select(nativeOwner(id: 'B'));
    h.target.select(h.owner);
    await tester.tap(find.text('Прочитать'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(field(tester, 'bearer').controller!.text, isEmpty);
    expect(field(tester, 'device').controller!.text, isEmpty);
    expect(field(tester, 'url').controller!.text, isEmpty);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Сохранить')).onPressed, isNull);
  });

  group('address proposed by the host', () {
    const proposal = 'https://synthetic.invalid/tenant/ms';
    const label = 'Подставить адрес с сервера чата';
    const buttonKey = ValueKey('surfaces-use-chat-address');

    testWidgets('one tap fills ONLY the address: no save, request, legacy read, bearer or Device ID', (tester) async {
      final h = await setup(tester, configured: false);
      final c = h.make();
      var legacyCalls = 0;
      await mountDialog(
        tester,
        c,
        suggested: proposal,
        legacy: () async {
          legacyCalls++;
          return nativeSettings();
        },
      );
      expect(find.text(label), findsOneWidget);
      expect(field(tester, 'url').controller!.text, isEmpty);
      final (reads, committedReads) = (h.reads.length, h.committedReads);

      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      await tester.runAsync(flushNative);

      expect(field(tester, 'url').controller!.text, proposal);
      expect(field(tester, 'bearer').controller!.text, isEmpty);
      expect(field(tester, 'device').controller!.text, isEmpty);
      expect(find.text(label), findsNothing, reason: 'nothing left to propose once the field has it');
      expect(h.writes, isEmpty);
      expect(h.clients, isEmpty, reason: 'no health request or any other transport');
      expect(legacyCalls, 0);
      expect(h.reads.length, reads, reason: 'no secure-storage read');
      expect(h.committedReads, committedReads);
      expect(h.keyReads, 0);
      expect(h.supportReads, 0);
      expect(c.activeConnection.value, isNull, reason: 'filling a field binds nothing');
      expect(find.text('Сохранить привязку Surfaces?'), findsNothing, reason: 'no confirmation was started');

      // The owner still types the Surfaces bearer and Device ID and confirms, exactly as before.
      await tester.enterText(find.byKey(const ValueKey('surfaces-bearer')), 'typed_separate_bearer');
      await tester.enterText(find.byKey(const ValueKey('surfaces-device')), 'typed_explicit_device');
      await confirmSave(tester);
      final saved = jsonDecode(h.writes.single.$2) as Map;
      expect(saved['baseUri'], proposal);
      expect(saved['bearer'], 'typed_separate_bearer');
      expect(saved['deviceId'], 'typed_explicit_device');
    });

    testWidgets('it replaces a different saved address only, then hides itself while the field matches', (
      tester,
    ) async {
      final h = await setup(tester);
      final c = h.make();
      await mountDialog(tester, c, suggested: proposal);
      expect(field(tester, 'url').controller!.text, 'https://synthetic.invalid/tenant');
      expect(find.text(label), findsOneWidget, reason: 'the saved address differs from the proposal');
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(field(tester, 'url').controller!.text, proposal);
      expect(field(tester, 'bearer').controller!.text, 'synthetic_surfaces_bearer');
      expect(field(tester, 'device').controller!.text, 'explicit_synthetic_device');
      expect(find.byKey(buttonKey), findsNothing);
      expect(h.writes, isEmpty);

      await tester.enterText(find.byKey(const ValueKey('surfaces-url')), 'https://elsewhere.invalid/tenant');
      await tester.pump();
      expect(find.byKey(buttonKey), findsOneWidget, reason: 'different again');
      await tester.enterText(find.byKey(const ValueKey('surfaces-url')), '  $proposal  ');
      await tester.pump();
      expect(find.byKey(buttonKey), findsNothing, reason: 'typing the proposal by hand is the same as the button');
      expect(h.writes, isEmpty);
    });

    test('local addresses are told apart from public ones', () {
      for (final local in [
        'http://127.0.0.1:18787',
        'http://localhost:8787/x',
        'http://192.168.1.20:8787',
        'http://10.0.0.5',
        'http://172.16.4.1',
        'http://172.31.255.1',
        'http://169.254.1.1',
        'http://phone.local:8787',
      ]) {
        expect(NativeAssociationDialog.isLocalAddress(Uri.parse(local)), isTrue, reason: local);
      }
      for (final public in [
        'https://synthetic.invalid/tenant',
        'https://203.0.113.7:8443/p/ms',
        'http://172.32.0.1',
        'http://100.128.0.1',
        'http://100.64.0.9', // a Tailscale/CGNAT address works from anywhere on the user's VPN: never replaced
        'http://192.169.0.1',
      ]) {
        expect(NativeAssociationDialog.isLocalAddress(Uri.parse(public)), isFalse, reason: public);
      }
    });

    testWidgets('a pasted token loses the spaces and newlines around it before it is saved', (tester) async {
      final h = await setup(tester, configured: false);
      final c = h.make();
      await mountDialog(tester, c);
      await tester.enterText(find.byKey(const ValueKey('surfaces-url')), 'https://synthetic.invalid/tenant');
      await tester.enterText(find.byKey(const ValueKey('surfaces-bearer')), '  typed_separate_bearer \n');
      await tester.enterText(find.byKey(const ValueKey('surfaces-device')), 'typed_explicit_device');
      await confirmSave(tester);
      final saved = jsonDecode(h.writes.single.$2) as Map;
      expect(saved['bearer'], 'typed_separate_bearer');
    });

    testWidgets('a check verdict is dropped when the fields changed while it was asking', (tester) async {
      final h = await setup(tester);
      final gate = Completer<void>();
      h.client = (connection) => FakeClient(connection, (request, c) async {
        await gate.future;
        return h.server.respond(request, c);
      });
      final c = h.make();
      await mountDialog(tester, c);
      await tester.ensureVisible(find.text('Проверить подключение'));
      await tester.tap(find.text('Проверить подключение'));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('surfaces-url')), 'https://elsewhere.invalid/tenant');
      await tester.pump();
      gate.complete();
      await tester.runAsync(flushNative);
      await tester.pumpAndSettle();
      expect(find.text('Сервер отвечает'), findsNothing, reason: 'that answer was for another address');
      expect(find.text('Проверяю…'), findsNothing, reason: 'and the progress is over');
      expect(h.writes, isEmpty);
    });

    testWidgets('a saved tunnel address is replaced by the proposal in the form only, with a note', (tester) async {
      final h = await setup(tester, configured: false);
      h.seed(settings: nativeSettings(url: 'http://127.0.0.1:18787'));
      final c = h.make();
      await mountDialog(tester, c, suggested: proposal);
      expect(field(tester, 'url').controller!.text, proposal);
      expect(field(tester, 'bearer').controller!.text, 'synthetic_surfaces_bearer');
      expect(find.byKey(const ValueKey('surfaces-address-swapped')), findsOneWidget);
      expect(find.byKey(buttonKey), findsNothing, reason: 'the field already has the proposal');
      expect(h.writes, isEmpty, reason: 'nothing is saved by showing it');

      await tester.enterText(find.byKey(const ValueKey('surfaces-url')), 'https://elsewhere.invalid/tenant');
      await tester.pump();
      expect(find.byKey(const ValueKey('surfaces-address-swapped')), findsNothing);
    });

    testWidgets('a local address read from the previous settings is replaced, the secrets are kept', (tester) async {
      final h = await setup(tester, configured: false);
      final c = h.make();
      await mountDialog(
        tester,
        c,
        suggested: proposal,
        legacy: () async => nativeSettings(
          url: 'http://192.168.1.20:8787',
          bearer: 'explicit_legacy_surfaces_only',
          device: 'explicit_legacy_device',
        ),
      );
      await tester.ensureVisible(find.text('Заполнить из прежних настроек…'));
      await tester.tap(find.text('Заполнить из прежних настроек…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Прочитать'));
      await tester.pumpAndSettle();
      expect(field(tester, 'url').controller!.text, proposal);
      expect(field(tester, 'bearer').controller!.text, 'explicit_legacy_surfaces_only');
      expect(field(tester, 'device').controller!.text, 'explicit_legacy_device');
      expect(find.byKey(const ValueKey('surfaces-address-swapped')), findsOneWidget);
      expect(h.writes, isEmpty);
    });

    testWidgets('nothing is replaced when both addresses are local or no proposal exists', (tester) async {
      final h = await setup(tester, configured: false);
      h.seed(settings: nativeSettings(url: 'http://127.0.0.1:18787'));
      final c = h.make();
      await mountDialog(tester, c, suggested: 'http://192.168.1.2:8642/ms');
      expect(field(tester, 'url').controller!.text, 'http://127.0.0.1:18787');
      expect(find.byKey(const ValueKey('surfaces-address-swapped')), findsNothing);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      await mountDialog(tester, c);
      expect(field(tester, 'url').controller!.text, 'http://127.0.0.1:18787');
      expect(find.byKey(const ValueKey('surfaces-address-swapped')), findsNothing);
    });

    testWidgets('no proposal, a blank one or an identical one shows no button', (tester) async {
      final h = await setup(tester);
      final c = h.make();
      await mountDialog(tester, c);
      expect(find.byKey(buttonKey), findsNothing);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      await mountDialog(tester, c, suggested: '   ');
      expect(find.byKey(buttonKey), findsNothing);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      await mountDialog(tester, c, suggested: 'https://synthetic.invalid/tenant');
      expect(field(tester, 'url').controller!.text, 'https://synthetic.invalid/tenant');
      expect(find.byKey(buttonKey), findsNothing);
    });

    testWidgets('filling the address discards an earlier connection check and sends nothing itself', (tester) async {
      final h = await setup(tester);
      final c = h.make();
      await mountDialog(tester, c, suggested: proposal);
      await tester.ensureVisible(find.text('Проверить подключение'));
      await tester.tap(find.text('Проверить подключение'));
      await tester.pump();
      await tester.runAsync(flushNative);
      await tester.pumpAndSettle();
      expect(find.text('Сервер отвечает'), findsOneWidget);
      expect(h.clients, hasLength(1));
      expect(h.clients.single.requests, hasLength(1), reason: 'the one explicit health request');

      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.text('Сервер отвечает'), findsNothing, reason: 'the verdict belonged to the old address');
      expect(h.clients, hasLength(1));
      expect(h.clients.single.requests, hasLength(1), reason: 'the button itself sent nothing');
      expect(h.writes, isEmpty);
    });

    testWidgets('a stale dialog keeps the button disabled and fills nothing', (tester) async {
      final h = await setup(tester);
      final c = h.make();
      await mountDialog(tester, c, suggested: proposal);
      h.target.select(nativeOwner(id: 'B'));
      h.target.select(h.owner);
      await tester.pumpAndSettle();
      expect(field(tester, 'url').controller!.text, isEmpty);
      expect(tester.widget<TextButton>(find.byKey(buttonKey)).onPressed, isNull);
      await tester.ensureVisible(find.byKey(buttonKey)); // below the paste block: off the first screen
      await tester.tap(find.byKey(buttonKey), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(field(tester, 'url').controller!.text, isEmpty);
      expect(h.writes, isEmpty);
    });

    testWidgets('320dp at 1.3x text scale: the long label wraps instead of overflowing', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final h = await setup(tester, configured: false);
      final c = h.make();
      await mountDialog(tester, c, suggested: proposal, textScale: 1.3);
      await tester.ensureVisible(find.text(label));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(buttonKey)).width, lessThanOrEqualTo(320));
      expect(tester.getSize(find.byKey(buttonKey)).height, greaterThanOrEqualTo(48));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(field(tester, 'url').controller!.text, proposal);
      expect(tester.takeException(), isNull);
    });
  });

  for (final action in ['selection', 'mutation', 'disposal']) {
    testWidgets('late legacy prefill after $action is discarded without writes', (tester) async {
      final h = await setup(tester);
      final c = h.make();
      final legacy = Completer<NativeAssociationSettings?>();
      var calls = 0;
      await mountDialog(
        tester,
        c,
        legacy: () {
          calls++;
          return legacy.future;
        },
      );
      await tester.ensureVisible(find.text('Заполнить из прежних настроек…'));
      await tester.tap(find.text('Заполнить из прежних настроек…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Прочитать'));
      await tester.pump();
      expect(calls, 1);
      NativeMutationOperation? op;
      if (action == 'selection') {
        h.target.select(nativeOwner(id: 'B'));
        h.target.select(h.owner);
      } else if (action == 'mutation') {
        op = h.mutations.begin();
      } else {
        c.dispose();
      }
      legacy.complete(nativeSettings(bearer: 'must_not_prefill'));
      await tester.pumpAndSettle();
      expect(field(tester, 'bearer').controller!.text, isEmpty);
      expect(field(tester, 'url').controller!.text, isEmpty);
      expect(h.writes, isEmpty);
      op?.finish(success: false);
      await tester.runAsync(flushNative);
      if (action == 'mutation') {
        // Settlement triggers a FRESH exact read of the durable record; the dead dialog token
        // (cleared fields, disabled Save) can still never write.
        expect(c.activeConnection.value!.config.credentialGeneration, 'synthetic_persisted_generation');
        expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Сохранить')).onPressed, isNull);
      } else {
        expect(c.activeConnection.value, isNull);
      }
      expect(h.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('legacy and storage exceptions display only sanitized messages', (tester) async {
    final h = await setup(tester);
    final c = h.make();
    await mountDialog(tester, c, legacy: () async => throw StateError('raw-synthetic-cookie-secret'));
    await tester.ensureVisible(find.text('Заполнить из прежних настроек…'));
    await tester.tap(find.text('Заполнить из прежних настроек…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Прочитать'));
    await tester.pumpAndSettle();
    expect(find.textContaining('raw-synthetic-cookie-secret'), findsNothing);
    expect(find.text('Не удалось прочитать прежние настройки Surfaces.'), findsOneWidget);
    h.write = (_, _) async => throw StateError('raw-synthetic-cookie-secret');
    await confirmSave(tester);
    expect(find.textContaining('raw-synthetic-cookie-secret'), findsNothing);
    expect(find.byType(NativeAssociationDialog), findsOneWidget);
    expect(c.activeConnection.value, isNull);
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    await tester.runAsync(flushNative);
    expect(c.activeConnection.value, isNull);
  });

  testWidgets('stale save confirmation performs no storage write and clears prefill', (tester) async {
    final h = await setup(tester);
    final c = h.make();
    await mountDialog(tester, c);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    h.target.select(nativeOwner(id: 'B'));
    h.target.select(h.owner);
    await tester.tap(find.text('Подтвердить сохранение'));
    await tester.pumpAndSettle();
    expect(h.writes, isEmpty);
    expect(field(tester, 'bearer').controller!.text, isEmpty);
    expect(c.activeConnection.value, isNull);
  });

  testWidgets('dialog disposed during begun secure save cannot publish or touch disposed text state', (tester) async {
    final h = await setup(tester);
    final c = h.make();
    await mountDialog(tester, c);
    final gate = Completer<void>();
    h.write = (key, value) async {
      await gate.future;
      h.storage[key] = value;
    };
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подтвердить сохранение'));
    await tester.pump();
    await tester.runAsync(flushNative);
    expect(h.writes.length, 1);
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    // The begun write is not cancellable; its stale completion publishes nothing by itself.
    expect(c.activeConnection.value, isNull);
    gate.complete();
    await tester.runAsync(flushNative);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Only a FRESH exact-context read of the durable record may bind, after every save settled.
    final durable = jsonDecode(h.storage.values.single) as Map;
    expect(durable['generation'], isNot('synthetic_persisted_generation'));
    expect(c.activeConnection.value!.config.credentialGeneration, durable['generation']);
    expect(h.reads.length, greaterThanOrEqualTo(3));
  });

  testWidgets('host disposing its controller while the tree unmounts cannot assert in an open dialog', (tester) async {
    final h = await setup(tester);
    final c = h.make();
    await tester.runAsync(flushNative);
    await tester.pumpWidget(
      localizedApp(
        home: _DisposingHost(
          controller: c,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNativeAssociationDialog(context, controller: c),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(NativeAssociationDialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'owned controller with unchanged Apps closes fresh clients/routes on native mutation; late HTTP rejected',
    (tester) async {
      final root = await tester.runAsync(() => Directory.systemTemp.createTemp('hermes_native_synthetic_'));
      final h = NativeHarness(root: root!);
      h.seed();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        h.dispose();
        await root.delete(recursive: true);
      });
      final c = h.make();
      await tester.runAsync(flushNative);
      final held = Completer<http.Response>();
      final sharedChat = FakeClient(c.activeConnection.value!, h.server.respond);
      var hold = false;
      h.client = (binding) {
        final client = FakeClient(
          binding,
          (req, connection) => hold && req.url.path.endsWith('/apps') ? held.future : h.server.respond(req, connection),
        );
        h.clients.add(client);
        return client;
      };
      SurfacePageRequest? oldRequest;
      await tester.pumpWidget(
        localizedApp(
          home: AppsModule(
            bridge: c,
            autoSync: false,
            surfacePageBuilder: (_, request) {
              oldRequest = request;
              return FakePage(request: request);
            },
          ),
        ),
      );
      await settle(tester);
      expect(find.text('Synthetic app'), findsOneWidget);
      expect(h.keyReads, 1); // Missing key does not block reads.
      await open(tester, 'Synthetic app');
      expect(find.text('Synthetic page renderer'), findsOneWidget);
      final old = oldRequest!;
      hold = true;
      final pending = old.host.api.listApps();
      final rejected = expectLater(pending, throwsA(isA<Exception>()));
      await tester.runAsync(flushNative);
      final op = h.mutations.begin();
      expect(c.activeConnection.value, isNull);
      expect(h.clients.every((client) => client.closes == 1), isTrue);
      h.committedOwner = nativeOwner(apiKey: 'changed_while_http_inflight');
      await tester.pumpAndSettle();
      expect(find.text('Synthetic page renderer'), findsNothing);
      expect(find.text('Приложение закрыто'), findsOneWidget);
      held.complete(
        jsonResponse({
          'apps': [
            {'appId': 'leaked', 'title': 'MUST NOT SHOW', 'revision': 1},
          ],
        }),
      );
      await tester.runAsync(flushNative);
      await rejected;
      await old.openChat();
      expect(h.chatCalls, 0);
      op.finish(success: true);
      await tester.runAsync(flushNative);
      await tester.pumpAndSettle();
      expect(find.text('MUST NOT SHOW'), findsNothing);
      expect(sharedChat.closes, 0);
      expect(h.writes, isEmpty);
    },
  );
}
