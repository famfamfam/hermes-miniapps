import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Per-session composer drafts so leaving a chat never loses typed text.
///
/// Persisted in [SharedPreferences] (device-local) and namespaced by
/// stable connection id + session id (base64url) so endpoint edits do not
/// strand drafts and identical session ids from different connections never
/// leak into each other. Empty text clears the entry: an abandoned draft must
/// not resurrect after the message was sent or deleted.
abstract final class ComposerDraftStore {
  static const _prefix = 'composer_draft';

  static String _key(String connectionId, String sessionId) {
    final namespace = base64Url
        .encode(utf8.encode('$connectionId\u0000$sessionId'))
        .replaceAll('=', '');
    return '$_prefix.$namespace';
  }

  static Future<String?> read({
    required String connectionId,
    required String sessionId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_key(connectionId, sessionId));
      return (value == null || value.trim().isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save({
    required String connectionId,
    required String sessionId,
    required String text,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _key(connectionId, sessionId);
      if (text.trim().isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, text);
      }
    } catch (_) {
      // Best-effort: a failed save must never break the screen.
    }
  }

  /// Drops the draft for one session.
  static Future<void> remove({
    required String connectionId,
    required String sessionId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(connectionId, sessionId));
    } catch (_) {
      // Best-effort.
    }
  }

  /// Drops every draft stored for [connectionId]: called when the user
  /// deletes a connection so orphaned drafts cannot accumulate.
  static Future<void> removeConnection(String connectionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final marker = '$connectionId\u0000';
      for (final key in prefs.getKeys()) {
        if (!key.startsWith('$_prefix.')) continue;
        final decoded = _decode(key);
        if (decoded != null && decoded.startsWith(marker)) {
          await prefs.remove(key);
        }
      }
    } catch (_) {
      // Best-effort.
    }
  }

  static String? _decode(String key) {
    final encoded = key.substring(_prefix.length + 1);
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    } catch (_) {
      return null;
    }
  }
}
