import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/one_signal_service.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Credentials implements CredentialStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  String? readCached(String key) => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  const subscription = MethodChannel('OneSignal#pushsubscription');
  const notifications = MethodChannel('OneSignal#notifications');
  const dialogTitle = 'Your OneSignal SDK integration is complete!';
  late SharedPreferences prefs;
  late ConnectionManager manager;
  String? currentId;
  bool grantPermission = false;
  bool failPermission = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    manager = await ConnectionManager.create(
      prefs,
      credentialStore: _Credentials(),
    );
    currentId = null;
    grantPermission = false;
    failPermission = false;
    OneSignalService.initialized = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(subscription, (call) async => currentId);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifications, (call) async {
          if (failPermission) throw PlatformException(code: 'unavailable');
          return grantPermission;
        });
  });

  tearDown(() {
    OneSignalService.initialized = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(subscription, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifications, null);
  });

  Future<void> sendSubscriptionChange(WidgetTester tester) async {
    const codec = StandardMethodCodec();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'OneSignal#pushsubscription',
      codec.encodeMethodCall(
        const MethodCall('OneSignal#onPushSubscriptionChange', {
          'current': {'id': 'server-id', 'optedIn': false},
          'previous': {'id': null, 'optedIn': false},
        }),
      ),
      (_) {},
    );
  }

  Future<void> sendClick(
    WidgetTester tester, {
    String? title,
    String? body,
  }) async {
    const codec = StandardMethodCodec();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'OneSignal#notifications',
      codec.encodeMethodCall(
        MethodCall('OneSignal#onClickNotification', {
          'notification': {
            'notificationId': 'test',
            'title': title,
            'body': body,
          },
          'result': <String, dynamic>{},
        }),
      ),
      (_) {},
    );
  }

  testWidgets('tap shows selectable notification text without a connection', (
    tester,
  ) async {
    await tester.pumpWidget(HermesApp(connManager: manager));
    await tester.pumpAndSettle();
    await sendClick(tester, title: 'Push title', body: '**plain body**');
    await tester.pumpAndSettle();
    expect(
      find.text('The notification text may be truncated.'),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == 'Push title',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == '**plain body**',
      ),
      findsOneWidget,
    );
    expect(prefs.getString('last_connection_id'), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tap without text shows an explanation', (tester) async {
    await tester.pumpWidget(HermesApp(connManager: manager));
    await tester.pumpAndSettle();
    await sendClick(tester, title: ' ', body: '');
    await tester.pumpAndSettle();
    expect(find.text('No notification text.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('early tap stays above automatic workspace navigation', (
    tester,
  ) async {
    await manager.saveConnection('Test server', '127.0.0.1', 1, 'key');
    await prefs.setString(
      'last_connection_id',
      manager.getConnections().single.id,
    );
    OneSignalService.registerClickListener();
    await sendClick(tester, body: 'Early push');
    await tester.pumpWidget(HermesApp(connManager: manager));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('Early push').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late subscription schedules a frame and shows setup', (
    tester,
  ) async {
    await tester.pumpWidget(HermesApp(connManager: manager));
    await tester.pumpAndSettle();
    expect(find.text(dialogTitle), findsNothing);
    await sendSubscriptionChange(tester);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpAndSettle();
    expect(find.text(dialogTitle), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fails in [false, true]) {
    testWidgets(
      'permission ${fails ? 'error' : 'denial'} can be retried next launch',
      (tester) async {
        currentId = 'server-id';
        failPermission = fails;
        await tester.pumpWidget(HermesApp(connManager: manager));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Got it'));
        await tester.pumpAndSettle();
        expect(prefs.getBool('onesignal_setup_dialog_shown'), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(HermesApp(connManager: manager));
        await tester.pumpAndSettle();
        expect(find.text(dialogTitle), findsOneWidget);
        grantPermission = true;
        failPermission = false;
        await tester.tap(find.text('Got it'));
        await tester.pumpAndSettle();
        expect(prefs.getBool('onesignal_setup_dialog_shown'), isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('setup stays above automatic workspace navigation', (
    tester,
  ) async {
    await manager.saveConnection('Test server', '127.0.0.1', 1, 'key');
    await prefs.setString(
      'last_connection_id',
      manager.getConnections().single.id,
    );
    currentId = 'server-id';
    await tester.pumpWidget(HermesApp(connManager: manager));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text(dialogTitle), findsOneWidget);
    expect(find.text('Got it').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
