import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';

import 'native_association_support.dart';
import 'support.dart';

/// Mimics a native Workspace State: attach in didChangeDependencies/didUpdateWidget, dispose.
class _Host extends StatefulWidget {
  const _Host({required this.binding, required this.owner, this.label = 'host', this.showChat = true, this.active = true});
  final NativeAppsBinding binding;
  final NativeOwnerSnapshot owner;
  final String label;
  final bool showChat;
  final bool active;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.binding.attach(context, widget.owner);
  }

  @override
  void didUpdateWidget(_Host oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.binding.attach(context, widget.owner);
  }

  @override
  void dispose() {
    widget.binding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.label)),
    body: NativeAppsPane(
      binding: widget.binding,
      autoSync: false,
      showChat: widget.showChat,
      active: widget.active,
      surfacePageBuilder: (_, request) => FakePage(request: request),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NativeHarness h;
  late NativeTargetRouteObserver observer;
  late Directory root;
  final navigator = GlobalKey<NavigatorState>();
  final events = <String>[];
  final created = <NativeAssociationController>[];
  final ownerB = nativeOwner(id: 'B', label: 'Other connection');

  NativeAppsBinding binding({
    Future<Directory> Function()? legacy,
    NativeAssociationController Function(NativeOwnerSnapshot, NativeTargetLease, Future<void> Function())? factory,
    String? Function(NativeOwnerSnapshot)? suggested,
    Future<bool> Function(String)? startChat,
  }) => NativeAppsBinding(
    startChatWithText: startChat,
    observer: observer,
    createController:
        factory ??
        (owner, lease, openChat) {
          final controller = h.make(snapshot: owner, lease: lease, openChat: openChat);
          created.add(controller);
          return controller;
        },
    selectChats: () async => events.add('chats'),
    openBrowser: () async => events.add('browser'),
    legacySettingsDirectory: legacy,
    suggestedSurfacesUrl: suggested,
  );

  Future<void> setUpHarness(WidgetTester tester, {bool seeded = true}) async {
    root = (await tester.runAsync(() => Directory.systemTemp.createTemp('hermes_binding_')))!;
    h = NativeHarness(root: root);
    if (seeded) h.seed();
    observer = NativeTargetRouteObserver(h.target);
    events.clear();
    created.clear();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink()); // Unmount first: hosts dispose their bindings.
      h.dispose();
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort: a Windows temp directory may still be held by a just-finished listing.
      }
    });
  }

  /// The controller loads asynchronously (in-memory callbacks): flush, rebuild, wait for Apps.
  Future<void> ready(WidgetTester tester) async {
    await tester.runAsync(flushNative);
    await tester.pump();
    await settle(tester);
  }

  Future<void> mountHost(WidgetTester tester, _Host host) =>
      tester.pumpWidget(localizedApp(navigatorKey: navigator, navigatorObservers: [observer], home: host));

  // Fixed pumps, not pumpAndSettle: a revealed Workspace's Apps module may be doing real file I/O
  // behind a progress indicator, which never "settles" under the fake clock.
  Future<void> push(WidgetTester tester, Widget page) async {
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pop(WidgetTester tester) async {
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('attach is idempotent, pane shows the catalogue and a label-only change keeps the controller', (
    tester,
  ) async {
    await setUpHarness(tester);
    final b = binding();
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await ready(tester);
    expect(created.length, 1);
    final first = created.single;
    expect(find.text('Synthetic app'), findsOneWidget);
    expect(find.byKey(const ValueKey('apps-status-chip')).evaluate().length, 1);
    expect(find.text('Онлайн'), findsOneWidget);
    final relabelled = nativeOwner(label: 'Renamed only');
    await mountHost(tester, _Host(binding: b, owner: relabelled));
    await tester.pump();
    expect(created, [first]);
    expect(b.controller, same(first));
    expect(first.activeConnection.value, isNotNull);
    expect(first.lease.isCurrent, isTrue);
  });

  testWidgets('a tab host turns the header chat button off, and hides the pane from polling, through the pane', (
    tester,
  ) async {
    await setUpHarness(tester);
    h.server.reviews = true; // the five-second tick then has previews to read
    final b = binding();
    await mountHost(tester, _Host(binding: b, owner: h.owner, showChat: false));
    await ready(tester);
    expect(find.text('Synthetic app'), findsOneWidget);
    expect(find.text('Открыть чат'), findsNothing, reason: 'the pane forwards showChat: false to the module');
    expect(find.byTooltip('Обновить'), findsOneWidget);

    // The default keeps the button, so a host that does not know the flag is unchanged.
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await tester.pump();
    expect(find.text('Открыть чат'), findsOneWidget);

    // The active flag reaches the module too. Control: shown, the five-second tick reads the previews.
    int previews() => h.clients.expand((c) => c.requests).where((r) => r.url.path.endsWith('/previews')).length;
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await tester.pump();
    final shown = previews();
    await tester.pump(const Duration(seconds: 5));
    expect(previews(), greaterThan(shown));
    // Hidden, the same tick reads nothing.
    await mountHost(tester, _Host(binding: b, owner: h.owner, active: false));
    await tester.pump();
    final before = previews();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 5));
    }
    expect(previews(), before, reason: 'the pane forwards active: false to the module');
  });

  testWidgets('a changed snapshot context disposes the old controller and registers a new lease', (tester) async {
    await setUpHarness(tester);
    final b = binding();
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await ready(tester);
    final old = created.single;
    final changed = nativeOwner(apiKey: 'rotated_synthetic_key');
    h.committedOwner = changed;
    await mountHost(tester, _Host(binding: b, owner: changed));
    await tester.runAsync(flushNative);
    await tester.pump();
    expect(created.length, 2);
    expect(old.lease.isCurrent, isFalse);
    expect(old.activeConnection.value, isNull);
    // The new snapshot has no association record under the same connection (fingerprint differs).
    expect(created.last.activeConnection.value, isNull);
    expect(created.last.owner, same(changed));
  });

  testWidgets('pane reports a missing association and exposes sanitised status', (tester) async {
    await setUpHarness(tester, seeded: false);
    final b = binding();
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await tester.runAsync(flushNative);
    await tester.pump();
    expect(find.textContaining('Surfaces не настроены'), findsWidgets);
    expect(created.single.activeConnection.value, isNull);
  });

  testWidgets('unconfigured pane is ONE onboarding card with ONE primary button, not two near-duplicate messages', (
    tester,
  ) async {
    await setUpHarness(tester, seeded: false);
    final b = binding();
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await tester.runAsync(flushNative);
    await tester.pump();
    expect(find.text('Surfaces не настроены'), findsOneWidget);
    expect(find.textContaining('Surfaces не настроены для выбранного подключения'), findsNothing);
    expect(find.textContaining('Чат доступен в основном приложении'), findsNothing);
    expect(find.text('Не настроено'), findsOneWidget);
    expect(find.text('Настроить Surfaces'), findsOneWidget);
    expect(find.text('Чат работает и без настройки.'), findsOneWidget);
    expect(find.text('Открыть чат'), findsOneWidget);
    await tester.tap(find.text('Открыть чат'));
    await tester.pump();
    expect(events, ['chats', 'browser'], reason: 'chat stays reachable without any configuration');
    expect(h.writes, isEmpty);
    expect(h.keyReads, 0);
    expect(h.supportReads, 0);
  });

  testWidgets('a configured pane reaches the same dialog from the header; nothing is read or written for it', (
    tester,
  ) async {
    await setUpHarness(tester);
    final b = binding();
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await ready(tester);
    expect(find.text('Онлайн'), findsOneWidget);
    expect(find.text('Настроить Surfaces'), findsNothing, reason: 'the card button only exists while unconfigured');
    await tester.tap(find.byTooltip('Настроить Surfaces'));
    await tester.pumpAndSettle();
    expect(find.byType(NativeAssociationDialog), findsOneWidget);
    expect(find.text('Проверить подключение'), findsOneWidget);
    await tester.tap(find.text('Закрыть'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // Fixed pumps: a bound module polls on a timer.
    expect(h.writes, isEmpty);
    await ready(tester);
    expect(created.single.activeConnection.value, isNotNull, reason: 'cancelling reloads the saved association');
    expect(find.text('Онлайн'), findsOneWidget);
  });

  testWidgets('a changed native context shows its sanitised reason once, as a notice, with chat still reachable', (
    tester,
  ) async {
    await setUpHarness(tester);
    final b = binding();
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await ready(tester);
    h.committedOwner = nativeOwner(apiKey: 'rotated_synthetic_key');
    final operation = h.mutations.begin();
    operation.finish(success: true);
    await tester.runAsync(flushNative);
    await tester.pump();
    expect(created.single.activeConnection.value, isNull);
    expect(find.textContaining('Контекст чата отличается'), findsOneWidget);
    expect(find.text('Недоступно'), findsOneWidget);
    expect(find.text('Surfaces не настроены'), findsNothing);
    expect(find.text('Открыть чат'), findsOneWidget);
  });

  testWidgets('Back to a covered Workspace replaces the controller with a NEW lease; stale callbacks do nothing', (
    tester,
  ) async {
    await setUpHarness(tester);
    final a = binding();
    final other = binding();
    await mountHost(tester, _Host(binding: a, owner: h.owner, label: 'A'));
    await ready(tester);
    final oldA = created.single;
    final oldChat = oldA.openChat;
    await push(tester, _Host(binding: other, owner: ownerB, label: 'B'));
    // Covered A is revoked at the moment B registers; a deferred notification is not required for safety.
    expect(oldA.lease.isCurrent, isFalse);
    expect(oldA.activeConnection.value, isNull);
    await oldChat();
    expect(events, isEmpty);
    expect(tester.takeException(), isNull);
    await pop(tester);
    await tester.runAsync(flushNative);
    await tester.pump();
    expect(created.length, 3); // A, B (unconfigured: committed owner is A), new A.
    final newA = created.last;
    expect(newA, isNot(same(oldA)));
    expect(newA.owner, same(h.owner));
    expect(a.controller, same(newA));
    expect(oldA.lease.isCurrent, isFalse);
    expect(newA.lease.isCurrent, isTrue);
    await ready(tester);
    expect(newA.activeConnection.value, isNotNull);
    expect(find.text('Synthetic app'), findsOneWidget);
    // A second attach after the reveal is idempotent.
    await tester.pump();
    expect(created.length, 3);
    await oldChat();
    expect(events, isEmpty);
  });

  testWidgets('selection from another entry path during build is deferred safely and never revives', (tester) async {
    await setUpHarness(tester);
    final a = binding();
    await mountHost(tester, _Host(binding: a, owner: h.owner, label: 'A'));
    await ready(tester);
    final first = created.single;
    expect(first.activeConnection.value, isNotNull);
    // Host B's registration selects inside didChangeDependencies without a prior explicit select.
    await push(tester, _Host(binding: binding(), owner: ownerB, label: 'B'));
    expect(tester.takeException(), isNull);
    expect(first.activeConnection.value, isNull);
    expect(h.target.current!.owner, same(ownerB));
    // Same-frame explicit A -> B -> A on top of the visible route cannot revive the old lease.
    final lease = h.target.select(h.owner);
    h.target.select(ownerB);
    expect(lease.isCurrent, isFalse);
    expect(first.lease.isCurrent, isFalse);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chat callback pops to the CAPTURED route, selects Chats then opens the browser', (tester) async {
    await setUpHarness(tester);
    final a = binding();
    await mountHost(tester, _Host(binding: a, owner: h.owner, label: 'A'));
    await ready(tester);
    // Same-owner nested routes (Surface/Chat) keep the lease.
    await push(tester, const Scaffold(body: Text('nested chat of the same owner')));
    await push(tester, const Scaffold(body: Text('deeper nested route')));
    final controller = created.single;
    expect(controller.lease.isCurrent, isTrue);
    await controller.openChat();
    await tester.pumpAndSettle();
    expect(events, ['chats', 'browser']);
    expect(find.text('nested chat of the same owner'), findsNothing);
    expect(find.text('A'), findsOneWidget);
    expect(navigator.currentState!.canPop(), isFalse);
  });

  testWidgets('a page starts a chat: back to the CAPTURED route, Chats selected, then the host sends the text', (
    tester,
  ) async {
    await setUpHarness(tester);
    final sent = <String>[];
    final a = binding(
      startChat: (text) async {
        events.add('start');
        sent.add(text);
        return true;
      },
    );
    await mountHost(tester, _Host(binding: a, owner: h.owner, label: 'A'));
    await ready(tester);
    await push(tester, const Scaffold(body: Text('the mini-app page')));
    expect(await a.startChat(created.single.lease, 'Разбери квитанцию'), isTrue);
    await tester.pumpAndSettle();
    expect(events, ['chats', 'start'], reason: 'Chats first, then the new chat; the chat browser is not opened');
    expect(sent, ['Разбери квитанцию']);
    expect(find.text('the mini-app page'), findsNothing);
    expect(navigator.currentState!.canPop(), isFalse);
  });

  testWidgets('a chat that the host could not start is reported as false', (tester) async {
    await setUpHarness(tester);
    final a = binding(startChat: (_) async => false);
    await mountHost(tester, _Host(binding: a, owner: h.owner, label: 'A'));
    await ready(tester);
    expect(await a.startChat(created.single.lease, 'hi'), isFalse);
  });

  testWidgets('no chat is started without a host hook, or for a lease that is stale', (tester) async {
    await setUpHarness(tester);
    final started = <String>[];
    final withoutHook = binding();
    await mountHost(tester, _Host(binding: withoutHook, owner: h.owner, label: 'A'));
    await ready(tester);
    expect(await withoutHook.startChat(created.single.lease, 'hi'), isFalse);
    expect(events, isEmpty, reason: 'nothing was navigated either');

    final stale = created.single;
    await push(
      tester,
      _Host(
        binding: binding(
          startChat: (t) async {
            started.add(t);
            return true;
          },
        ),
        owner: ownerB,
        label: 'B',
      ),
    );
    await push(tester, const Scaffold(body: Text('B nested')));
    expect(await withoutHook.startChat(stale.lease, 'late'), isFalse);
    expect(find.text('B nested'), findsOneWidget, reason: 'a stale page pops nothing');
    expect(started, isEmpty);
  });

  testWidgets('Chat callback never pops above its route when the lease, route or host is stale', (tester) async {
    await setUpHarness(tester);
    final a = binding();
    await mountHost(tester, _Host(binding: a, owner: h.owner, label: 'A'));
    await ready(tester);
    final staleLease = created.single;
    await push(tester, _Host(binding: binding(), owner: ownerB, label: 'B'));
    await push(tester, const Scaffold(body: Text('B nested')));
    await staleLease.openChat();
    await tester.pumpAndSettle();
    expect(events, isEmpty);
    expect(find.text('B nested'), findsOneWidget); // Nothing was popped.

    // Revealing A again issues a NEW lease; a second Workspace A2 for the same owner then
    // revokes it. After A2 is popped away (its State and route are gone) neither the A2 callback
    // nor the superseded A callback can navigate, whichever order they run in.
    await pop(tester);
    await pop(tester);
    await tester.runAsync(flushNative);
    final supersededA = created.last;
    await push(tester, _Host(binding: binding(), owner: h.owner, label: 'A2'));
    final a2 = created.last;
    await pop(tester);
    await a2.openChat();
    await supersededA.openChat();
    expect(events, isEmpty);
  });

  testWidgets('dispose unregisters the route, clears the visible target and disposes the controller', (tester) async {
    await setUpHarness(tester);
    final a = binding();
    await mountHost(tester, _Host(binding: a, owner: h.owner));
    await ready(tester);
    final controller = created.single;
    expect(h.target.current, same(controller.lease));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
    expect(h.target.current, isNull);
    expect(a.controller, isNull);
    expect(controller.activeConnection.value, isNull);
    await controller.openChat();
    expect(events, isEmpty);
    // A disposed binding can never be re-attached.
    final context = tester.element(find.byType(SizedBox));
    a.attach(context, h.owner);
    expect(a.controller, isNull);
    expect(created.length, 1);
  });

  testWidgets('a throwing controller factory fails closed and leaves the pane unavailable', (tester) async {
    await setUpHarness(tester);
    final b = binding(factory: (_, _, _) => throw StateError('raw-synthetic-secret'));
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(b.controller, isNull);
    expect(find.text('Surfaces недоступны. Чат остаётся доступен.'), findsOneWidget);
    expect(find.textContaining('raw-synthetic-secret'), findsNothing);
  });

  testWidgets('configuration action opens the owned dialog; legacy file is read only after consent', (tester) async {
    await setUpHarness(tester, seeded: false);
    final legacy = Directory('${root.path}/legacy')..createSync();
    final file = File('${legacy.path}/settings.json');
    file.writeAsStringSync(
      jsonEncode({
        'url': 'https://legacy.synthetic.invalid/tenant',
        'token': 'legacy_example_token',
        'deviceId': 'legacy_example_device',
        'sealNetwork': false,
      }),
    );
    final before = file.readAsStringSync();
    final directoryCalls = <int>[];
    final b = binding(
      legacy: () async {
        directoryCalls.add(1);
        return legacy;
      },
    );
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await tester.runAsync(flushNative);
    await tester.pump();
    await tester.tap(find.byTooltip('Настроить Surfaces'));
    await tester.pumpAndSettle();
    // The onboarding card's button has the same label as the dialog title: look inside the dialog.
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Настроить Surfaces')), findsOneWidget);
    expect(directoryCalls, isEmpty);
    await tester.ensureVisible(find.text('Заполнить из прежних настроек…'));
    await tester.tap(find.text('Заполнить из прежних настроек…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(directoryCalls, isEmpty);
    await tester.tap(find.text('Заполнить из прежних настроек…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Прочитать'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester); // The legacy read performs real file I/O.
    expect(directoryCalls.length, 1);
    final bearer = tester.widget<TextField>(find.byKey(const ValueKey('surfaces-bearer')));
    expect(bearer.controller!.text, 'legacy_example_token');
    expect(h.writes, isEmpty);
    expect(file.readAsStringSync(), before);
    expect(legacy.listSync().length, 1);
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    expect(h.writes, isEmpty);
  });

  testWidgets('the host proposal is asked once for the controller owner and only fills the address field', (
    tester,
  ) async {
    await setUpHarness(tester);
    final asked = <NativeOwnerSnapshot>[];
    final b = binding(
      suggested: (owner) {
        asked.add(owner);
        return 'https://synthetic.invalid/${owner.connectionId}/ms';
      },
    );
    await mountHost(tester, _Host(binding: b, owner: h.owner));
    await ready(tester);
    expect(asked, isEmpty, reason: 'nothing is asked until the dialog is opened');
    final (keyReads, supportReads) = (h.keyReads, h.supportReads); // The bound catalogue read them already.
    await tester.tap(find.byTooltip('Настроить Surfaces'));
    await tester.pumpAndSettle();
    expect(asked, hasLength(1));
    expect(asked.single, same(created.single.owner));
    final url = tester.widget<TextField>(find.byKey(const ValueKey('surfaces-url'))).controller!;
    expect(url.text, 'https://synthetic.invalid/tenant', reason: 'the saved address is what the dialog opens with');
    await tester.ensureVisible(find.text('Подставить адрес с сервера чата'));
    await tester.tap(find.text('Подставить адрес с сервера чата'));
    await tester.pumpAndSettle();
    expect(url.text, 'https://synthetic.invalid/synthetic_connection/ms');
    final bearer = tester.widget<TextField>(find.byKey(const ValueKey('surfaces-bearer'))).controller!;
    expect(bearer.text, 'synthetic_surfaces_bearer', reason: 'the saved bearer is neither replaced nor cleared');
    expect(h.writes, isEmpty);
    expect(h.keyReads, keyReads);
    expect(h.supportReads, supportReads);
    await tester.tap(find.text('Закрыть'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // Fixed pumps: the rebinding catalogue polls on a timer.
    expect(h.writes, isEmpty);
    await ready(tester);
    expect(created.single.activeConnection.value, isNotNull, reason: 'cancelling reloads the saved association');
  });

  for (final entry in <String, String? Function(NativeOwnerSnapshot)?>{
    'throwing': (_) => throw StateError('raw-synthetic-secret'),
    'null': (_) => null,
    'absent': null,
  }.entries) {
    testWidgets('a ${entry.key} host proposal never breaks the setup dialog and shows no button', (tester) async {
      await setUpHarness(tester, seeded: false);
      final b = binding(suggested: entry.value);
      await mountHost(tester, _Host(binding: b, owner: h.owner));
      await tester.runAsync(flushNative);
      await tester.pump();
      await tester.tap(find.byTooltip('Настроить Surfaces'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(NativeAssociationDialog), findsOneWidget);
      expect(find.text('Подставить адрес с сервера чата'), findsNothing);
      expect(find.textContaining('raw-synthetic-secret'), findsNothing);
      expect(h.writes, isEmpty);
    });
  }

  test('legacy example settings are parsed read-only with defaults and fixed errors', () async {
    final dir = Directory.systemTemp.createTempSync('hermes_legacy_');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(await readLegacyExampleSettings(dir), isNull);
    final file = File('${dir.path}/settings.json');
    file.writeAsStringSync(
      jsonEncode({'url': 'https://synthetic.invalid/t', 'token': 'legacy_token', 'deviceId': 'legacy_device'}),
    );
    final settings = (await readLegacyExampleSettings(dir))!;
    expect(settings.baseUri.toString(), 'https://synthetic.invalid/t');
    expect(settings.bearer, 'legacy_token');
    expect(settings.deviceId, 'legacy_device');
    expect(settings.strictNetworkBlock, isTrue);
    expect(settings.sealNetwork, isTrue);
    expect(dir.listSync().length, 1); // No generated device ID/key/seed or sibling files.
    for (final bad in <String>[
      'not json secret-token',
      '[]',
      jsonEncode({'url': 1, 'token': 'secret-token', 'deviceId': 'd'}),
      jsonEncode({'url': 'https://synthetic.invalid', 'token': 'secret-token'}),
      jsonEncode({'url': 'https://synthetic.invalid', 'token': 't', 'deviceId': 'd', 'sealNetwork': 'yes'}),
    ]) {
      file.writeAsStringSync(bad);
      await expectLater(
        readLegacyExampleSettings(dir),
        throwsA(isA<FormatException>().having((e) => e.toString(), 'message', isNot(contains('secret-token')))),
      );
      expect(file.readAsStringSync(), bad);
    }
  });
}
