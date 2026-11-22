import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OneSignalService {
  OneSignalService._();

  static const _appId = String.fromEnvironment('ONESIGNAL_APP_ID');
  static const appIdKey = 'onesignal_app_id';
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static bool initialized = false;
  static bool _clickListenerRegistered = false;
  static final List<OSNotificationClickEvent> _pendingClicks = [];
  static void Function()? onClicksAvailable;

  static void registerClickListener() {
    if (_clickListenerRegistered) return;
    _clickListenerRegistered = true;
    addClickListener((event) {
      _pendingClicks.add(event);
      onClicksAvailable?.call();
    });
  }

  static List<OSNotificationClickEvent> takePendingClicks() {
    final clicks = List<OSNotificationClickEvent>.of(_pendingClicks);
    _pendingClicks.clear();
    return clicks;
  }

  static bool isValidAppId(String value) => _uuid.hasMatch(value);

  static String appIdFor(SharedPreferences prefs) {
    final saved = prefs.getString(appIdKey)?.trim() ?? '';
    return isValidAppId(saved) ? saved : _appId;
  }

  static Future<bool> saveAppId(SharedPreferences prefs, String value) async {
    final id = value.trim();
    if (id.isEmpty) return prefs.remove(appIdKey);
    if (!isValidAppId(id)) {
      throw const FormatException('Invalid OneSignal App ID');
    }
    return prefs.setString(appIdKey, id);
  }

  static Future<void> initialize(SharedPreferences prefs) async {
    final appId = appIdFor(prefs);
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        appId.isEmpty) {
      return;
    }
    try {
      final initialization = OneSignal.initialize(appId);
      registerClickListener();
      await initialization;
      initialized = true;
    } catch (error) {
      debugPrint('OneSignal initialization failed: $error');
    }
  }

  static bool isRegistered(String? id) =>
      id != null && id.isNotEmpty && !id.startsWith('local-');

  // SDK 5.5.2 reads its cached ID before registering the native observer.
  static Future<String?> readSubscriptionId() async {
    const channel = MethodChannel('OneSignal#pushsubscription');
    final id = await channel.invokeMethod<String>(
      'OneSignal#pushSubscriptionId',
    );
    return id ?? OneSignal.User.pushSubscription.id;
  }

  static void addObserver(OnPushSubscriptionChangeObserver observer) =>
      OneSignal.User.pushSubscription.addObserver(observer);

  static void removeObserver(OnPushSubscriptionChangeObserver observer) =>
      OneSignal.User.pushSubscription.removeObserver(observer);

  static void addClickListener(OnNotificationClickListener listener) =>
      OneSignal.Notifications.addClickListener(listener);

  static void removeClickListener(OnNotificationClickListener listener) =>
      OneSignal.Notifications.removeClickListener(listener);

  static Future<bool> requestPermission() =>
      OneSignal.Notifications.requestPermission(true);
}
