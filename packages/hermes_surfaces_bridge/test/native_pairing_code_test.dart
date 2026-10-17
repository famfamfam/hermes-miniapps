import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:http/http.dart' as http;

import 'native_association_support.dart';
import 'support.dart';

/// The chat flow: Hermes sends a connection line, the user pastes it, the one-time code is spent for the
/// token and this phone's key is registered as approver, and the result is saved like a typed setup.

String line({String url = 'https://host.example:8443/secretpath/ms', String code = 'ABCDEFGHIJKLMNOPQRSTUV'}) =>
    'HAP1.${base64Url.encode(utf8.encode(jsonEncode({'u': url, 'c': code}))).replaceAll('=', '')}';

typedef Claim = http.Response Function(http.Request request);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApproverKey key;
  setUp(() async => key = await ApproverKey.fromSeed(Uint8List(32)));

  /// A harness whose network is [claim]: every request lands in [seen].
  NativeHarness harness(Claim claim, List<http.Request> seen, {bool withKey = true}) {
    final h = NativeHarness();
    if (withKey) h.createKey = () async => key;
    h.client = (connection) => FakeClient(connection, (req, _) {
      seen.add(req);
      return claim(req);
    });
    addTearDown(h.dispose);
    return h;
  }

  http.Response granted([bool approver = true]) =>
      jsonResponse({'token': 'issued_surfaces_token', 'approverPaired': approver});

  Future<NativeClaimResult> connect(
    NativeHarness h, {
    String? deviceId,
    bool strict = true,
    bool seal = true,
    ConnectionString? code,
  }) async {
    final controller = h.make();
    await flushNative();
    final configuration = controller.beginConfiguration();
    return controller.connectWithCode(
      configuration,
      code ?? ConnectionString.tryParse(line())!,
      deviceId: deviceId,
      strictNetworkBlock: strict,
      sealNetwork: seal,
    );
  }

  Map<String, dynamic> saved(NativeHarness h) => jsonDecode(h.writes.single.$2) as Map<String, dynamic>;

  group('spending the code', () {
    test('sends the code and this phone\'s key without any bearer, then saves the token like a typed setup', () async {
      final seen = <http.Request>[];
      final h = harness((_) => granted(), seen);

      final result = await connect(h, deviceId: 'existing_phone', strict: false, seal: true);

      expect(result, NativeClaimResult.connected);
      expect(seen, hasLength(1));
      final request = seen.single;
      expect(request.url.toString(), 'https://host.example:8443/secretpath/ms$apiPrefix/devices/claim');
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(request.body), {
        'code': 'ABCDEFGHIJKLMNOPQRSTUV',
        'deviceId': 'existing_phone',
        'publicKey': key.publicKeyBase64,
      });
      final record = saved(h);
      expect(record['baseUri'], 'https://host.example:8443/secretpath/ms');
      expect(record['bearer'], 'issued_surfaces_token');
      expect(record['deviceId'], 'existing_phone', reason: 'an existing Device ID is kept');
      expect(record['strictNetworkBlock'], isFalse);
      expect(record['sealNetwork'], isTrue);
      expect(h.keyCreations, 1);
    });

    test('without a Device ID the phone names itself; ids are valid and differ', () async {
      final ids = <String>{};
      for (var i = 0; i < 3; i++) {
        final seen = <http.Request>[];
        final h = harness((_) => granted(), seen);
        await connect(h);
        final id = saved(h)['deviceId'] as String;
        expect(NativeAssociationSettings.isValidDeviceId(id), isTrue, reason: id);
        expect(id, matches(RegExp(r'^phone-[a-z0-9]{8}$')));
        expect((jsonDecode(seen.single.body) as Map)['deviceId'], id);
        ids.add(id);
      }
      expect(ids.length, greaterThan(1));
    });

    test('an invalid Device ID is replaced, never sent', () async {
      final seen = <http.Request>[];
      final h = harness((_) => granted(), seen);
      await connect(h, deviceId: 'Pixel 7');
      expect(saved(h)['deviceId'], isNot('Pixel 7'));
    });

    test('another approver: connected, saved, but the phone is told it cannot confirm', () async {
      final h = harness((_) => granted(false), []);
      expect(await connect(h), NativeClaimResult.connectedNotApprover);
      expect(saved(h)['bearer'], 'issued_surfaces_token');
    });

    final refusals = <String, (http.Response, NativeClaimResult)>{
      'a wrong or expired code': (jsonResponse({'error': 'the connection code is wrong or has expired'}, 400), NativeClaimResult.invalidCode),
      'too many attempts': (jsonResponse({'error': 'slow down'}, 429), NativeClaimResult.locked),
      'an older server': (jsonResponse({'detail': 'Not Found'}, 404), NativeClaimResult.unsupported),
      'a server error': (jsonResponse({'error': 'boom'}, 500), NativeClaimResult.failed),
    };
    for (final entry in refusals.entries) {
      test('${entry.key}: nothing is saved', () async {
        final h = harness((_) => entry.value.$1, []);
        expect(await connect(h), entry.value.$2);
        expect(h.writes, isEmpty);
      });
    }

    test('no answer from the server is "unreachable" and nothing is saved', () async {
      final h = NativeHarness()..createKey = (() async => key);
      h.client = (connection) => FakeClient(connection, (_, _) => throw http.ClientException('down'));
      addTearDown(h.dispose);
      expect(await connect(h), NativeClaimResult.unreachable);
      expect(h.writes, isEmpty);
    });

    test('a controller that cannot create a key never contacts the server', () async {
      final seen = <http.Request>[];
      final h = harness((_) => granted(), seen, withKey: false);
      expect(await connect(h), NativeClaimResult.failed);
      expect(seen, isEmpty);
      expect(h.writes, isEmpty);
    });

    test('a key that cannot be created ends before any request', () async {
      final seen = <http.Request>[];
      final h = harness((_) => granted(), seen)..createKey = (() async => throw StateError('disk'));
      expect(await connect(h), NativeClaimResult.failed);
      expect(seen, isEmpty);
    });

    test('a save that fails is a failure (the spent code is gone, the user asks for a new one)', () async {
      final h = harness((_) => granted(), []);
      h.write = (_, _) async => throw StateError('secure storage');
      expect(await connect(h), NativeClaimResult.failed);
    });

    test('a target change before the request means no request at all', () async {
      final seen = <http.Request>[];
      final h = harness((_) => granted(), seen);
      final controller = h.make();
      await flushNative();
      final configuration = controller.beginConfiguration();
      h.target.select(nativeOwner(id: 'B'));
      final result = await controller.connectWithCode(configuration, ConnectionString.tryParse(line())!);
      expect(result, NativeClaimResult.stale);
      expect(seen, isEmpty);
      expect(h.writes, isEmpty);
      expect(h.keyCreations, 0, reason: 'a stale setup must not even create the approver key');
    });

    test('a shared client is refused like everywhere else: clients must be fresh', () async {
      final seen = <http.Request>[];
      final h = harness((_) => granted(), seen);
      final shared = FakeClient(
        connection(),
        (req, _) {
          seen.add(req);
          return granted();
        },
      );
      h.client = (_) => shared;
      expect(await connect(h), NativeClaimResult.connected);
      expect(await connect(h), NativeClaimResult.unreachable, reason: 'the same instance twice');
    });
  });

  group('the paste step in the dialog', () {
    String? clipboard;
    var clipboardReads = 0;

    setUp(() {
      clipboard = null;
      clipboardReads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
        call,
      ) async {
        if (call.method == 'Clipboard.getData') {
          clipboardReads++;
          return clipboard == null ? null : <String, dynamic>{'text': clipboard};
        }
        return null;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    Future<void> open(WidgetTester tester, NativeHarness h, {bool startWithPaste = false}) async {
      final controller = h.make();
      await tester.runAsync(flushNative);
      await tester.pumpWidget(
        localizedApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showNativeAssociationDialog(context, controller: controller, startWithPaste: startWithPaste),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    const pasteKey = ValueKey('surfaces-paste-code');

    testWidgets('the clipboard is read only when the button is pressed, and then only the host is shown', (tester) async {
      clipboard = 'Вот строка:\n${line()}\nвставьте её в приложение';
      final seen = <http.Request>[];
      final h = harness((_) => granted(), seen);
      await open(tester, h);
      expect(clipboardReads, 0, reason: 'opening the dialog reads nothing');
      expect(find.text('Вставить код подключения'), findsOneWidget);

      await tester.tap(find.byKey(pasteKey));
      await tester.pumpAndSettle();
      expect(clipboardReads, 1);
      expect(find.text('Подключиться к host.example:8443?'), findsOneWidget);
      expect(find.textContaining('secretpath'), findsNothing, reason: 'the path holds a secret prefix');
      expect(find.textContaining('ABCDEFGHIJKLMNOPQRSTUV'), findsNothing, reason: 'the code is never shown');
      expect(seen, isEmpty, reason: 'nothing is sent before the user agrees');

      await tester.tap(find.text('Подключить'));
      await tester.pump();
      await tester.runAsync(flushNative);
      await tester.pumpAndSettle();
      expect(seen, hasLength(1));
      expect(h.writes, hasLength(1));
      expect(find.byKey(pasteKey), findsNothing, reason: 'the dialog closed after connecting');
      expect(find.text('Подключено к Hermes'), findsOneWidget);
    });

    testWidgets('declining the question sends and saves nothing', (tester) async {
      clipboard = line();
      final seen = <http.Request>[];
      final h = harness((_) => granted(), seen);
      await open(tester, h);
      await tester.tap(find.byKey(pasteKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(seen, isEmpty);
      expect(h.writes, isEmpty);
      expect(find.byKey(pasteKey), findsOneWidget, reason: 'the dialog is still open');
    });

    testWidgets('a clipboard without a code says so and asks nothing', (tester) async {
      for (final text in <String?>[null, '', 'just words', 'HAP1.@@@']) {
        clipboard = text;
        final seen = <http.Request>[];
        final h = harness((_) => granted(), seen);
        await open(tester, h);
        await tester.tap(find.byKey(pasteKey));
        await tester.pumpAndSettle();
        expect(find.textContaining('В буфере обмена нет кода подключения'), findsOneWidget, reason: '$text');
        expect(find.textContaining('Подключиться к'), findsNothing);
        expect(seen, isEmpty);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('an expired code keeps the dialog open with the reason', (tester) async {
      clipboard = line();
      final h = harness((_) => jsonResponse({'error': 'x'}, 400), []);
      await open(tester, h);
      await tester.tap(find.byKey(pasteKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подключить'));
      await tester.pump();
      await tester.runAsync(flushNative);
      await tester.pumpAndSettle();
      expect(find.textContaining('Код неверный или устарел'), findsOneWidget);
      expect(h.writes, isEmpty);
      expect(find.byKey(pasteKey), findsOneWidget);
    });

    testWidgets('opened with startWithPaste it goes straight to the question', (tester) async {
      clipboard = line();
      final h = harness((_) => granted(), []);
      await open(tester, h, startWithPaste: true);
      expect(clipboardReads, 1);
      expect(find.text('Подключиться к host.example:8443?'), findsOneWidget);
    });

    testWidgets('an older server without codes points to the manual form', (tester) async {
      clipboard = line();
      final h = harness((_) => jsonResponse({'detail': 'Not Found'}, 404), []);
      await open(tester, h);
      await tester.tap(find.byKey(pasteKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подключить'));
      await tester.pump();
      await tester.runAsync(flushNative);
      await tester.pumpAndSettle();
      expect(find.textContaining('не поддерживает коды подключения'), findsOneWidget);
      expect(find.byKey(const ValueKey('surfaces-url')), findsOneWidget, reason: 'the manual fields are right there');
    });
  });
}
