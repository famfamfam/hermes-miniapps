import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local cache of a sent message's binary attachments.
///
/// The Hermes gateway stores chat history as text only (images become
/// `[screenshot]`, documents an `@file <path>` line), so after a chat is
/// reopened the server history carries no pixels. This store keeps the data
/// URLs the app itself sent, namespaced by connection + session, so the
/// message bubbles can restore thumbnails and tappable file cards. Entries
/// expire 90 days after their last write; a failed save must never break the
/// screen.
abstract final class SentAttachmentCache {
  static const _prefix = 'sent_attachments';
  static const _lifetime = Duration(days: 90);

  @visibleForTesting
  static String key(String connectionId, String sessionId) {
    final namespace = base64Url
        .encode(utf8.encode('$connectionId\u0000$sessionId'))
        .replaceAll('=', '');
    return '$_prefix.$namespace';
  }

  /// All cached turn payloads for one chat, oldest first. Each entry holds
  /// the sent text and the attachment parts of that turn.
  static Future<List<CachedSentAttachments>> readAll(
    String connectionId,
    String sessionId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key(connectionId, sessionId));
      if (raw == null) return const [];
      final turns = (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(CachedSentAttachments.fromJson)
          .where((turn) => turn.age < _lifetime)
          .toList();
      return turns;
    } catch (_) {
      return const [];
    }
  }

  /// Appends one turn and drops expired turns. [maxTurns] bounds the file
  /// size; the oldest turns go first.
  static Future<void> append(
    String connectionId,
    String sessionId,
    CachedSentAttachments turn, {
    int maxTurns = 50,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storeKey = key(connectionId, sessionId);
      final turns = (jsonDecode(prefs.getString(storeKey) ?? '[]') as List)
          .cast<Map<String, dynamic>>()
          .map(CachedSentAttachments.fromJson)
          .toList()
        ..add(turn)
        ..removeWhere((item) => item.age >= _lifetime);
      while (turns.length > maxTurns) {
        turns.removeAt(0);
      }
      await prefs.setString(storeKey, jsonEncode(turns));
    } catch (_) {
      // Best-effort.
    }
  }

  /// Drops the whole chat's cache: called when the connection is deleted so
  /// orphaned payloads cannot accumulate.
  static Future<void> remove(String connectionId, String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key(connectionId, sessionId));
    } catch (_) {
      // Best-effort.
    }
  }

  /// Drops every chat cache stored for [connectionId].
  static Future<void> removeConnection(String connectionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith('$_prefix.')) continue;
        final decoded = _decode(key);
        if (decoded != null && decoded.startsWith('$connectionId\u0000')) {
          await prefs.remove(key);
        }
      }
    } catch (_) {
      // Best-effort.
    }
  }

  static String? _decode(String storeKey) {
    final encoded = storeKey.substring(_prefix.length + 1);
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    } catch (_) {
      return null;
    }
  }
}

/// One sent turn: its text and the attachment parts as they went to the wire.
@immutable
class CachedSentAttachments {
  final int savedAtMs;
  final String text;
  final List<String> imageDataUrls;
  final List<Map<String, String>> files;

  const CachedSentAttachments({
    required this.savedAtMs,
    required this.text,
    required this.imageDataUrls,
    required this.files,
  });

  Duration get age =>
      DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(savedAtMs));

  Map<String, dynamic> toJson() => {
    'savedAt': savedAtMs,
    'text': text,
    'images': imageDataUrls,
    'files': files,
  };

  factory CachedSentAttachments.fromJson(Map<String, dynamic> json) =>
      CachedSentAttachments(
        savedAtMs: (json['savedAt'] as num?)?.toInt() ?? 0,
        text: json['text'] as String? ?? '',
        imageDataUrls: (json['images'] as List?)?.cast<String>() ?? const [],
        files: [
          for (final file in (json['files'] as List?) ?? const <dynamic>[])
            if (file is Map)
              <String, String>{
                'filename': file['filename']?.toString() ?? 'document',
                'fileData': file['file_data']?.toString() ?? '',
              },
        ],
      );
}
