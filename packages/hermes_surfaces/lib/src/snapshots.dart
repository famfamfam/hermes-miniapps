import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// A stored server answer for one group of queries (ADR-009 §4).
class Snapshot {
  Snapshot({
    required this.fetchedAt,
    required this.dataRev,
    required this.results,
  });
  final DateTime fetchedAt;
  final int dataRev;
  final Map<String, dynamic> results;
}

/// Query snapshots, separate from installed bundles and from drafts. Cleared by cache cleanup.
///
/// Spike simplification: keyed per *group* of calls rather than per query, because the server
/// answers a group from one dataRev and mixing revisions would not be a consistent snapshot.
class SnapshotCache {
  SnapshotCache(this.root, {this.maxFiles = 200});

  /// `<support>/surfaces/<scope>`
  final Directory root;
  final int maxFiles;

  Directory _dir(String appId) => Directory('${root.path}/apps/$appId/snapshots');

  /// Key covers contract, arguments and the time context, so different filters or a changed
  /// time zone never share an entry. Different contracts never share one either.
  static String keyFor({
    required String contractHash,
    required List<Map<String, dynamic>> calls,
    required String timezone,
    required String today,
  }) {
    final canonical = jsonEncode({'c': contractHash, 'q': _canon(calls), 'tz': timezone, 'd': today});
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  static Object? _canon(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: _canon(v[k])};
    }
    if (v is List) return v.map(_canon).toList();
    return v;
  }

  // Writers of one snapshot file are queued, by path and not by object identity: a reload or a
  // hermes:data-changed event can start the same group query twice, and both answers are stored
  // under one key. Without the queue the renames collide on Windows (access denied / not found).
  static final Map<String, Future<void>> _writes = {};
  static int _attempt = 0;

  /// A temp file this old belongs to a writer that died, not to one still running.
  static const Duration _abandonedTempAge = Duration(minutes: 10);

  static Future<T> _serialize<T>(String path, Future<T> Function() operation) async {
    final key = Platform.isWindows ? path.toLowerCase() : path;
    final previous = _writes[key];
    final done = Completer<void>();
    _writes[key] = done.future;
    try {
      if (previous != null) await previous;
      return await operation();
    } finally {
      if (identical(_writes[key], done.future)) _writes.remove(key);
      done.complete(); // queue tails never fail, even when an operation throws
    }
  }

  Future<void> put(String appId, String key, Snapshot s) async {
    final dir = _dir(appId);
    final target = File('${dir.path}/$key.json');
    await _serialize(p.normalize(target.absolute.path), () async {
      await dir.create(recursive: true);
      // Unique per call, so another process or isolate writing the same key cannot share it.
      final tmp = File('${dir.path}/$key.$pid-${DateTime.now().microsecondsSinceEpoch}-${_attempt++}.tmp');
      try {
        await tmp.writeAsString(jsonEncode({
          'fetchedAt': s.fetchedAt.toUtc().toIso8601String(),
          'dataRev': s.dataRev,
          'results': s.results,
        }), flush: true);
        await tmp.rename(target.path);
      } catch (_) {
        await _tryDelete(tmp);
        rethrow;
      }
    });
    await _evict(dir);
  }

  Future<Snapshot?> get(String appId, String key) async {
    final f = File('${_dir(appId).path}/$key.json');
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return Snapshot(
        fetchedAt: DateTime.parse(j['fetchedAt'] as String),
        dataRev: j['dataRev'] as int,
        results: Map<String, dynamic>.from(j['results'] as Map),
      );
    } catch (_) {
      await _tryDelete(f); // unreadable or already evicted: either way there is no snapshot
      return null;
    }
  }

  static Future<void> _tryDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // Already gone, or held open by another writer; the next eviction pass retries.
    }
  }

  /// Keeps the newest [maxFiles] snapshots and drops temp files of writers that died. Best effort:
  /// the snapshot being stored is already in place, so a failure here must not fail the put.
  Future<void> _evict(Directory dir) async {
    try {
      final abandoned = DateTime.now().subtract(_abandonedTempAge);
      final snapshots = <(File, DateTime)>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final stat = await e.stat();
        if (stat.type == FileSystemEntityType.notFound) continue;
        if (e.path.endsWith('.tmp')) {
          if (stat.modified.isBefore(abandoned)) await _tryDelete(e);
        } else if (e.path.endsWith('.json')) {
          snapshots.add((e, stat.modified));
        }
      }
      if (snapshots.length <= maxFiles) return;
      snapshots.sort((a, b) {
        final byTime = a.$2.compareTo(b.$2);
        return byTime != 0 ? byTime : a.$1.path.compareTo(b.$1.path);
      });
      for (final (file, _) in snapshots.take(snapshots.length - maxFiles)) {
        await _tryDelete(file);
      }
    } on FileSystemException {
      // The directory vanished (cache cleanup) or is unreadable: nothing to evict.
    }
  }

  Future<void> clearAll() async {
    final apps = Directory('${root.path}/apps');
    if (!await apps.exists()) return;
    await for (final e in apps.list()) {
      final snap = Directory('${e.path}/snapshots');
      if (await snap.exists()) await snap.delete(recursive: true);
    }
  }
}
