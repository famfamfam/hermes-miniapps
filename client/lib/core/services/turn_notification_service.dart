import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_prefs.dart';

/// Delivered to the app root when the user taps a notification body or one of
/// its action buttons. Set once by the root widget; every service instance
/// wires its plugin to this single handler so tap routing cannot depend on
/// which screen happened to initialise last.
void Function(NotificationResponse response)? notificationResponseHandler;

/// The Android/iOS notification channel a [TurnNotification] belongs to.
///
/// Phase 3 of the daily-driver roadmap replaces the single Hermes Turns
/// channel with four prioritized channels; describing the channel as data
/// keeps that change testable.
class TurnNotificationChannel {
  final String id;
  final String name;
  final String description;

  const TurnNotificationChannel({
    required this.id,
    required this.name,
    required this.description,
  });
}

/// Visual urgency for a notification: [high] lets the OS show a heads-up card
/// (attention kinds), [low] keeps finished background work quiet.
enum TurnNotificationImportance { low, defaultImportance, high }

/// An action button rendered on the notification itself. Pressing it brings
/// the app forward (`showsUserInterface`) so the live app answers the request
/// instead of a background isolate that cannot reach the gateway.
class TurnNotificationAction {
  final String id;
  final String label;

  const TurnNotificationAction({required this.id, required this.label});
}

/// A notification Hermes wants Android to post, described as plain data.
class TurnNotification {
  final int id;
  final String title;
  final String body;
  final String payload;
  final TurnNotificationChannel channel;
  final List<TurnNotificationAction> actions;
  final TurnNotificationImportance importance;

  const TurnNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.payload,
    required this.channel,
    this.actions = const [],
    this.importance = TurnNotificationImportance.defaultImportance,
  });
}

/// The platform seam [TurnNotificationService] posts through.
///
/// The production implementation is [PluginTurnNotificationSink]; tests supply
/// a recording double so notification behaviour can be verified without a
/// platform channel.
abstract class TurnNotificationSink {
  Future<void> initialize();

  /// Asks the platform for permission to post notifications.
  ///
  /// Returns `true` when granted, `false` when denied, and `null` when the
  /// platform has no runtime gate (iOS, Android < 13) — in which case posting
  /// is already allowed.
  Future<bool?> requestPermission();

  /// The tap or action that launched a terminated app, when the platform
  /// reports one. Consumed once by the service so a cold start still routes.
  Future<NotificationResponse?> takeInitialLaunchResponse();

  Future<void> show(TurnNotification notification);

  Future<void> cancel(int id);

  Future<void> cancelAll();
}

/// Default sink backed by `flutter_local_notifications`.
class PluginTurnNotificationSink implements TurnNotificationSink {
  final FlutterLocalNotificationsPlugin _plugin;

  PluginTurnNotificationSink({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  @override
  Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        notificationResponseHandler?.call(response);
      },
    );
  }

  @override
  Future<bool?> requestPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return android.requestNotificationsPermission();
    }

    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (ios != null) {
      return ios.requestPermissions(alert: true, badge: true, sound: true);
    }

    // No platform implementation resolved: nothing gates posting here.
    return null;
  }

  @override
  Future<NotificationResponse?> takeInitialLaunchResponse() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details?.notificationResponse;
  }

  @override
  Future<void> show(TurnNotification notification) async {
    final (importance, priority) = switch (notification.importance) {
      TurnNotificationImportance.high => (Importance.high, Priority.high),
      TurnNotificationImportance.low => (Importance.low, Priority.low),
      TurnNotificationImportance.defaultImportance => (
        Importance.defaultImportance,
        Priority.defaultPriority,
      ),
    };
    final androidDetails = AndroidNotificationDetails(
      notification.channel.id,
      notification.channel.name,
      channelDescription: notification.channel.description,
      importance: importance,
      priority: priority,
      autoCancel: true,
      actions: [
        for (final action in notification.actions)
          AndroidNotificationAction(
            action.id,
            action.label,
            showsUserInterface: true,
          ),
      ],
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      notification.id,
      notification.title,
      notification.body,
      details,
      payload: notification.payload,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id);

  @override
  Future<void> cancelAll() => _plugin.cancelAll();
}

/// Delivers Android notifications when a gateway turn completes while the app
/// is backgrounded, mirroring the Hermes Desktop tray notification behaviour.
///
/// The service owns a single notification channel ("Hermes Turns") and exposes
/// one idempotent [ensureInitialized] method safe to call from any lifecycle
/// point (including before the Flutter engine binding is ready).
class TurnNotificationService {
  static const turnChannel = TurnNotificationChannel(
    id: 'hermes_turn_notifications',
    name: 'Hermes Turns',
    description: 'Notifications for completed background turns',
  );

  /// Attention kinds get their own high-importance channel so approvals and
  /// input requests can surface as heads-up cards while the app is away.
  static const attentionChannel = TurnNotificationChannel(
    id: 'hermes_attention',
    name: 'Hermes Attention',
    description: 'Approvals and input requests that need you',
  );

  /// Finished background work: quiet by design.
  static const backgroundChannel = TurnNotificationChannel(
    id: 'hermes_background',
    name: 'Hermes Background',
    description: 'Background task completions',
  );

  /// Gateway notices: credits and plugin messages.
  static const noticesChannel = TurnNotificationChannel(
    id: 'hermes_notices',
    name: 'Hermes Notices',
    description: 'Credit and plugin notices',
  );

  /// The app-wide instance used outside tests, so every dispatcher shares one
  /// plugin, one initialisation and one tap handler.
  static TurnNotificationService? _shared;

  static TurnNotificationService get shared =>
      _shared ??= TurnNotificationService();

  /// The channel a [kind] posts on.
  static TurnNotificationChannel channelFor(HermesNotificationKind kind) =>
      switch (kind) {
        HermesNotificationKind.approval ||
        HermesNotificationKind.input => attentionChannel,
        HermesNotificationKind.turnDone ||
        HermesNotificationKind.turnError => turnChannel,
        HermesNotificationKind.backgroundDone => backgroundChannel,
        HermesNotificationKind.credits ||
        HermesNotificationKind.plugin => noticesChannel,
      };

  /// Visual urgency a [kind] posts with.
  static TurnNotificationImportance importanceFor(
    HermesNotificationKind kind,
  ) => switch (kind) {
    HermesNotificationKind.approval ||
    HermesNotificationKind.input => TurnNotificationImportance.high,
    HermesNotificationKind.backgroundDone => TurnNotificationImportance.low,
    _ => TurnNotificationImportance.defaultImportance,
  };

  final TurnNotificationSink _sink;

  bool _initialized = false;
  bool _permissionGranted = true;

  TurnNotificationService({
    TurnNotificationSink? sink,
    FlutterLocalNotificationsPlugin? plugin,
  }) : _sink = sink ?? PluginTurnNotificationSink(plugin: plugin);

  /// Whether the platform currently allows Hermes to post notifications.
  ///
  /// `false` means Android 13+ denied POST_NOTIFICATIONS: turns still complete
  /// but the OS drops every notification, so the UI can surface that instead of
  /// leaving the user wondering why nothing arrives.
  bool get permissionGranted => _permissionGranted;

  /// One-shot initialisation of the Hermes notification channel.
  ///
  /// Safe to call repeatedly — once it has succeeded, subsequent calls are
  /// no-ops. A failed attempt (platform channel unavailable, e.g. in tests)
  /// degrades to a silent no-op and may be retried later.
  Future<void> ensureInitialized() async {
    if (_initialized) return;

    try {
      await _sink.initialize();
      _initialized = true;
    } catch (_) {
      // Platform not available (e.g. test environment) — notifications
      // silently degrade to no-op.
      return;
    }

    // Android 13+ denies POST_NOTIFICATIONS until it is requested at runtime,
    // even though the manifest declares it. Without this, every notification
    // is dropped by the OS with no error surfaced anywhere.
    try {
      final granted = await _sink.requestPermission();
      _permissionGranted = granted ?? true;
    } catch (_) {
      // A failing permission channel must not break the app; assume the
      // platform imposes no runtime gate rather than blocking notifications.
      _permissionGranted = true;
    }
  }

  /// Posts a notification when a gateway turn completes while the app is
  /// backgrounded.
  ///
  /// [turnSummary] is a short description (e.g. session title or prompt
  /// excerpt); [turnId] ensures the notification is stable and replaceable.
  /// [sessionId]/[connectionId] are carried in the payload so a tap can route
  /// back to the originating chat, even across multiple connections.
  Future<void> showTurnCompleted({
    required String title,
    required String turnSummary,
    required String turnId,
    String? sessionId,
    String? connectionId,
  }) async {
    if (!_initialized) return;
    final identity = _turnIdentity(
      turnId: turnId,
      sessionId: sessionId,
      connectionId: connectionId,
    );
    // Replayed settlement callbacks must not alert repeatedly.
    if (_throttled('${HermesNotificationKind.turnDone.name}:$identity')) {
      return;
    }

    await _sink.show(
      TurnNotification(
        id: notificationIdFor(identity),
        title: title,
        body: turnSummary,
        payload: _turnPayload(
          turnId: turnId,
          sessionId: sessionId,
          connectionId: connectionId,
        ),
        channel: turnChannel,
      ),
    );
  }

  /// Cancels a specific turn notification.
  Future<void> cancelTurnCompleted(
    String turnId, {
    String? sessionId,
    String? connectionId,
  }) async {
    if (!_initialized) return;
    await _sink.cancel(
      notificationIdFor(
        _turnIdentity(
          turnId: turnId,
          sessionId: sessionId,
          connectionId: connectionId,
        ),
      ),
    );
  }

  /// Posts the failure counterpart of [showTurnCompleted] on the same channel,
  /// so the two kinds share one Android channel but keep separate toggles.
  Future<void> showTurnFailed({
    required String title,
    required String turnSummary,
    required String turnId,
    String? sessionId,
    String? connectionId,
  }) async {
    if (!_initialized) return;
    final identity = _turnIdentity(
      turnId: turnId,
      sessionId: sessionId,
      connectionId: connectionId,
    );
    // Replayed settlement callbacks must not alert repeatedly.
    if (_throttled('${HermesNotificationKind.turnError.name}:$identity')) {
      return;
    }

    await _sink.show(
      TurnNotification(
        id: notificationIdFor(identity),
        title: title,
        body: turnSummary,
        payload: _turnPayload(
          turnId: turnId,
          sessionId: sessionId,
          connectionId: connectionId,
        ),
        channel: turnChannel,
      ),
    );
  }

  /// JSON payload so a tap can route back to the originating chat, even
  /// across multiple connections.
  static String _turnPayload({
    required String turnId,
    String? sessionId,
    String? connectionId,
  }) => jsonEncode({
    'turnId': turnId,
    if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
    if (connectionId != null && connectionId.isNotEmpty)
      'connectionId': connectionId,
  });

  static String _turnIdentity({
    required String turnId,
    String? sessionId,
    String? connectionId,
  }) => jsonEncode([connectionId ?? '', sessionId ?? '', turnId]);

  // De-dupe replayed events for the same full event identity. Self-evicting:
  // entries older than the window are pruned on every dispatch, so the map
  // can't grow.
  static const _throttleWindowMs = 1000;
  final Map<String, int> _lastFiredAt = {};

  bool _throttled(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastFiredAt.removeWhere((_, at) => now - at >= _throttleWindowMs);
    if (_lastFiredAt.containsKey(key)) return true;
    _lastFiredAt[key] = now;
    return false;
  }

  /// Posts one native notification for [kind] when the device allows it.
  ///
  /// Callers gate on the app being backgrounded; this method enforces the
  /// user's per-kind preferences and the 1s replay throttle. Returns whether
  /// the notification was handed to the platform.
  Future<bool> showKind({
    required HermesNotificationKind kind,
    required String title,
    required String body,
    required String eventId,
    String? sessionId,
    String? connectionId,
    List<TurnNotificationAction> actions = const [],
    String? payload,
  }) async {
    if (!_initialized) return false;
    if (!notificationKindEnabled(kind)) return false;

    final identity = jsonEncode([
      kind.name,
      connectionId ?? '',
      sessionId ?? '',
      eventId,
    ]);
    if (_throttled(identity)) return false;

    await _sink.show(
      TurnNotification(
        id: notificationIdFor(identity),
        title: title,
        body: body,
        payload: payload ?? '',
        channel: channelFor(kind),
        actions: actions,
        importance: importanceFor(kind),
      ),
    );
    return true;
  }

  /// Settings "send test": bypasses gating like the desktop panel does, so a
  /// silent OS-level permission failure can be told apart from a dead feature.
  Future<bool> sendTestNotification({
    required String title,
    required String body,
  }) async {
    if (!_initialized) {
      await ensureInitialized();
      if (!_initialized) return false;
    }

    try {
      await _sink.show(
        TurnNotification(
          id: notificationIdFor('hermes-notification-test'),
          title: title,
          body: body,
          payload: 'test',
          channel: turnChannel,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _initialLaunchConsumed = false;

  /// The tap or action that launched a terminated app, if any — consumed once
  /// so a cold start still routes to the originating chat.
  Future<NotificationResponse?> takeInitialNotificationResponse() async {
    if (_initialLaunchConsumed) return null;
    _initialLaunchConsumed = true;
    try {
      return await _sink.takeInitialLaunchResponse();
    } catch (_) {
      return null;
    }
  }

  /// Removes all Hermes turn notifications.
  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _sink.cancelAll();
  }

  /// Stable, non-negative Android notification id derived from [turnId].
  ///
  /// Masking instead of negating keeps the id inside the 31-bit range Android
  /// accepts, and keeps one turn mapped to exactly one notification so a turn
  /// replaces its own notification instead of stacking duplicates.
  static int notificationIdFor(String turnId) => turnId.hashCode & 0x7fffffff;
}

/// A notification tap or action, parsed from the platform response payload.
///
/// Current payloads are JSON (`sessionId`/`connectionId`/`requestId`); older
/// turn notifications carried a plain turn id, which parses to a route with
/// no routing fields.
@immutable
class NotificationRoute {
  final String? sessionId;
  final String? connectionId;
  final String? requestId;
  final String? actionId;

  const NotificationRoute({
    this.sessionId,
    this.connectionId,
    this.requestId,
    this.actionId,
  });

  static NotificationRoute fromResponse(NotificationResponse response) {
    String? sessionId;
    String? connectionId;
    String? requestId;
    final raw = response.payload;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          sessionId = decoded['sessionId']?.toString();
          connectionId = decoded['connectionId']?.toString();
          requestId = decoded['requestId']?.toString();
        }
      } catch (_) {
        // A plain-string payload (older turns) carries only the turn id.
      }
    }
    return NotificationRoute(
      sessionId: sessionId,
      connectionId: connectionId,
      requestId: requestId,
      actionId: response.actionId,
    );
  }

  /// The approval choice an action press maps to, or null for a body tap.
  String? get approvalChoice => switch (actionId) {
    'approve' => 'once',
    'reject' => 'deny',
    _ => null,
  };
}

/// An approval a notification action could not answer directly — the request
/// belongs to an open chat's route-local gateway. That chat screen consumes
/// this and responds through its own gateway.
@immutable
class PendingNotificationApproval {
  /// The connection the notification named, so ids can never cross gateways.
  final String connectionId;
  final String sessionId;
  final String requestId;
  final String choice;

  const PendingNotificationApproval({
    required this.connectionId,
    required this.sessionId,
    required this.requestId,
    required this.choice,
  });
}

/// Approvals notification actions left behind for open chats to answer.
///
/// A list, not a single slot: several taps in a row (or two sessions on one
/// connection) must not overwrite each other. Entries stay until the owning
/// chat confirms the answer, so a cold start or a throw never loses a tap.
final ValueNotifier<List<PendingNotificationApproval>>
pendingNotificationApprovals = ValueNotifier(const []);

/// Queues [approval], deduplicating by connection + session + request.
void addPendingNotificationApproval(PendingNotificationApproval approval) {
  final existing = pendingNotificationApprovals.value;
  final duplicate = existing.any(
    (item) =>
        item.connectionId == approval.connectionId &&
        item.sessionId == approval.sessionId &&
        item.requestId == approval.requestId,
  );
  if (duplicate) return;
  pendingNotificationApprovals.value = [...existing, approval];
}

/// Removes [approval] once its owner confirmed it was answered.
void removePendingNotificationApproval(PendingNotificationApproval approval) {
  pendingNotificationApprovals.value = [
    for (final item in pendingNotificationApprovals.value)
      if (item.connectionId != approval.connectionId ||
          item.sessionId != approval.sessionId ||
          item.requestId != approval.requestId)
        item,
  ];
}
