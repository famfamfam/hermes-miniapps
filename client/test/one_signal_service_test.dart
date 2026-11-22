import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/one_signal_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const buildId = String.fromEnvironment('ONESIGNAL_APP_ID');
  const savedId = '12345678-abcd-1234-abcd-123456789abc';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OneSignalService.initialized = false;
  });

  testWidgets('resolves saved ID, fallback and invalid values', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    expect(OneSignalService.appIdFor(prefs), buildId);
    expect(await OneSignalService.saveAppId(prefs, '  $savedId  '), isTrue);
    expect(prefs.getString(OneSignalService.appIdKey), savedId);
    expect(OneSignalService.appIdFor(prefs), savedId);
    await expectLater(
      OneSignalService.saveAppId(prefs, 'bad'),
      throwsFormatException,
    );
    expect(OneSignalService.appIdFor(prefs), savedId);
    await prefs.setString(OneSignalService.appIdKey, 'corrupt');
    expect(OneSignalService.appIdFor(prefs), buildId);
    await OneSignalService.saveAppId(prefs, '  ');
    expect(OneSignalService.appIdFor(prefs), buildId);
  });

  testWidgets(
    'startup initializes Android with the saved ID before app state',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await OneSignalService.saveAppId(prefs, savedId);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final messenger = tester.binding.defaultBinaryMessenger;
      final channels = [
        'OneSignal',
        'OneSignal#inappmessages',
        'OneSignal#user',
        'OneSignal#pushsubscription',
        'OneSignal#notifications',
      ];
      String? initializedId;
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          if (call.method == 'OneSignal#initialize') {
            initializedId = call.arguments['appId'] as String;
          }
          if (call.method == 'OneSignal#permission' ||
              call.method == 'OneSignal#pushSubscriptionOptedIn') {
            return false;
          }
          return null;
        });
      }
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        OneSignalService.initialized = false;
        for (final name in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(name), null);
        }
      });
      await OneSignalService.initialize(prefs);
      expect(initializedId, savedId);
      expect(OneSignalService.initialized, isTrue);
      if (buildId.isNotEmpty) {
        await OneSignalService.saveAppId(prefs, '');
        initializedId = null;
        await OneSignalService.initialize(prefs);
        expect(initializedId, buildId);
      }
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('reads the current native ID after observer registration', (
    tester,
  ) async {
    const channel = MethodChannel('OneSignal#pushsubscription');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'OneSignal#pushSubscriptionId');
      return 'server-id';
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    expect(await OneSignalService.readSubscriptionId(), 'server-id');
  });

  test('only a server-assigned subscription is ready', () {
    expect(OneSignalService.isRegistered(null), isFalse);
    expect(OneSignalService.isRegistered(''), isFalse);
    expect(OneSignalService.isRegistered('local-123'), isFalse);
    expect(OneSignalService.isRegistered('subscription-123'), isTrue);
  });
}
