import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'api.dart';
import 'bundle_store.dart';
import 'bundle_verify.dart';
import 'snapshots.dart';
import 'strings.dart' show SurfacesText;

/// What this host build can run. Checked against every manifest before install (ADR-005 §4).
const List<int> supportedSdkMajors = [1];
const List<String> supportedCapabilities = <String>[];

enum Connectivity { unknown, online, offline, unauthorized }

class HostError implements Exception {
  HostError(this.code, this.message, {this.key});

  /// Stable code sent to the page: offline_no_snapshot, stale_revision, unauthorized,
  /// incompatible, bad_request, server_error, preview_gone.
  final String code;

  /// English diagnostic text, or a server-provided message. User interfaces show the localized
  /// text for [key] when there is one and this message otherwise.
  final String message;
  final SurfacesText? key;
  @override
  String toString() => '$code: $message';
}

class QueryOutcome {
  QueryOutcome({required this.reply, required this.fromCache, this.fetchedAt});
  final Map<String, dynamic> reply;
  final bool fromCache;
  final DateTime? fetchedAt;
}

/// Coordinates API, installed bundles and snapshots. UI-free so it can be tested.
class SurfacesHost {
  SurfacesHost({required this.api, required this.bundles, required this.snapshots, this.clock = DateTime.now});

  final SurfacesApi api;
  final BundleStore bundles;
  final SnapshotCache snapshots;
  final DateTime Function() clock;

  // A separate queue from BundleStore's filesystem lock: fetching a manifest, comparing the
  // current pointer, downloading and installing form one ordered operation across hosts sharing
  // the same cache root/app. Reusing the store queue here would deadlock on bundles.install.
  static final Map<(String, String), Future<void>> _updates = {};

  Future<T> _coordinateUpdate<T>(String appId, Future<T> Function() operation) async {
    final path = p.normalize(bundles.root.absolute.path);
    final key = (Platform.isWindows ? path.toLowerCase() : path, appId);
    final previous = _updates[key];
    final done = Completer<void>();
    _updates[key] = done.future;
    try {
      if (previous != null) await previous;
      return await operation();
    } finally {
      if (identical(_updates[key], done.future)) _updates.remove(key);
      done.complete(); // failed refreshes must not poison later checks
    }
  }

  final ValueNotifierLite<Connectivity> connectivity = ValueNotifierLite(Connectivity.unknown);

  void _markOnline() => connectivity.value = Connectivity.online;

  /// Why the newest server version was refused while an older one keeps running, per app.
  /// Shown by the UI; cleared by the next successful install.
  final Map<String, String> updateProblems = {};

  /// Installs or updates [appId] if the server has a different bundle. Whatever goes wrong with
  /// the *candidate* (offline, server error, bad bundle, bad manifest, incompatible SDK, disk
  /// full), an installed working version is returned instead; only with nothing installed does
  /// it throw, since a first start needs a network and a good package. A preview's 404 is different:
  /// review ended, so its cached bundle must not reopen as a build awaiting approval.
  Future<InstalledApp> ensureInstalled(String appId) async {
    if (!isValidAppId(appId)) {
      throw HostError('bad_request', 'Invalid app identifier', key: SurfacesText.hostBadAppId);
    }
    return _coordinateUpdate(appId, () => _ensureInstalled(appId));
  }

  Future<InstalledApp> _ensureInstalled(String appId) async {
    final current = await bundles.current(appId);
    try {
      final manifest = await api.manifest(appId);
      _markOnline();
      if (current != null &&
          current.bundleId == manifest.bundleId &&
          current.revision == manifest.revision &&
          current.preview == manifest.preview) {
        updateProblems.remove(appId);
        return current;
      }
      final installed = await _install(appId, manifest);
      updateProblems.remove(appId);
      return installed;
    } on OfflineException {
      connectivity.value = Connectivity.offline;
      if (current != null) return current;
      throw HostError(
        'offline_first_start',
        'The app is not downloaded yet; a connection to Hermes is needed',
        key: SurfacesText.hostOfflineFirstStart,
      );
    } on ApiException catch (e) {
      _classify(e);
      final error = _toHostError(e);
      if (error.code == 'preview_gone') throw error;
      if (current != null && !e.isUnauthorized) return current;
      throw error;
    } on BundleException catch (e) {
      return _keepRunning(appId, current, e.message, e);
    } on ManifestException catch (e) {
      return _keepRunning(appId, current, e.message, e);
    } on HostError catch (e) {
      return _keepRunning(appId, current, e.message, e);
    } on FileSystemException catch (e) {
      return _keepRunning(appId, current, 'could not write the bundle: ${e.message}', e);
    }
  }

  InstalledApp _keepRunning(String appId, InstalledApp? current, String reason, Exception cause) {
    if (current == null) throw cause;
    updateProblems[appId] = reason;
    return current;
  }

  /// Returns the newly installed version, or null when nothing changed or the check failed.
  /// If another host already installed the server version, returns that current disk version when
  /// its full identity differs from [displayed], without downloading it again. Omitting [displayed]
  /// keeps the usual null result for an unchanged disk install.
  /// Throws preview_gone when the server confirms that this build is no longer under review.
  Future<InstalledApp?> checkForUpdate(String appId, {InstalledApp? displayed}) async {
    if (!isValidAppId(appId)) return null;
    return _coordinateUpdate(appId, () => _checkForUpdate(appId, displayed: displayed));
  }

  bool _sameInstalledIdentity(InstalledApp a, InstalledApp b) =>
      a.appId == b.appId &&
      a.bundleId == b.bundleId &&
      a.revision == b.revision &&
      a.contractHash == b.contractHash &&
      a.epoch == b.epoch &&
      a.preview == b.preview;

  Future<InstalledApp?> _checkForUpdate(String appId, {InstalledApp? displayed}) async {
    final current = await bundles.current(appId);
    try {
      final manifest = await api.manifest(appId);
      _markOnline();
      if (current != null &&
          current.bundleId == manifest.bundleId &&
          current.revision == manifest.revision &&
          current.preview == manifest.preview) {
        return displayed != null && !_sameInstalledIdentity(current, displayed) ? current : null;
      }
      final installed = await _install(appId, manifest);
      updateProblems.remove(appId);
      return installed;
    } on OfflineException {
      connectivity.value = Connectivity.offline;
      return null;
    } on ApiException catch (e) {
      _classify(e);
      final error = _toHostError(e);
      if (error.code == 'preview_gone') throw error;
      return null;
    } on BundleException catch (e) {
      updateProblems[appId] = e.message; // bad candidate: the previous version keeps running
      return null;
    } on ManifestException catch (e) {
      updateProblems[appId] = e.message;
      return null;
    } on HostError catch (e) {
      updateProblems[appId] = e.message;
      return null;
    } on FileSystemException catch (e) {
      updateProblems[appId] = 'could not write the bundle: ${e.message}';
      return null;
    }
  }

  /// [appId] is what the caller asked for; the manifest was already checked to be for the same
  /// app, and every path below uses this value, never a name taken from the network.
  Future<InstalledApp> _install(String appId, AppManifest manifest) async {
    if (!supportedSdkMajors.contains(manifest.sdkMajor) || manifest.bundleFormat != supportedBundleFormat) {
      throw HostError(
        'incompatible',
        'This app needs a different client version (SDK ${manifest.sdkMajor})',
        key: SurfacesText.hostIncompatible,
      );
    }
    final needed = List<String>.from(manifest.bundle['capabilities'] as List);
    final missing = needed.where((c) => !supportedCapabilities.contains(c)).toList();
    if (missing.isNotEmpty) {
      throw HostError('incompatible', 'Unsupported capabilities: $missing', key: SurfacesText.hostIncompatible);
    }

    final zip = await api.fetchBundle(appId, manifest.bundleId);
    final verified = verifyBundle(zip, expectedId: manifest.bundleId);
    return bundles.install(
      appId,
      verified,
      title: manifest.title,
      revision: manifest.revision,
      contractHash: manifest.contractHash,
      epoch: manifest.epoch,
      preview: manifest.preview,
    );
  }

  /// Live answer when the server is reachable (and stored as a snapshot); otherwise the stored
  /// snapshot for exactly these arguments, or an explicit "not downloaded" error. An empty
  /// list is never fabricated for data that was never fetched.
  Future<QueryOutcome> query(InstalledApp app, List<Map<String, dynamic>> calls, {required String timezone}) async {
    final today = _today(timezone);
    final key = SnapshotCache.keyFor(contractHash: app.contractHash, calls: calls, timezone: timezone, today: today);
    try {
      final reply = await api.queryGroup(app.appId, app.revision, calls, timezone: timezone);
      _markOnline();
      final now = clock();
      final snapshot = Snapshot(
        fetchedAt: now,
        dataRev: reply['dataRev'] as int,
        results: Map<String, dynamic>.from(reply['results'] as Map),
      );
      try {
        await snapshots.put(app.appId, key, snapshot);
      } on Exception {
        // The snapshot only serves a later offline start. A full disk, a removed cache directory or
        // a rename that lost a race must not throw away an answer the server just gave. An Error
        // (a bug) still propagates; so does a malformed reply above, which is not a cache problem.
      }
      return QueryOutcome(
        fromCache: false,
        fetchedAt: now,
        reply: {
          'dataRev': reply['dataRev'],
          'fetchedAt': now.toUtc().toIso8601String(),
          'freshness': 'live',
          'results': reply['results'],
        },
      );
    } on OfflineException {
      connectivity.value = Connectivity.offline;
      final snap = await snapshots.get(app.appId, key);
      if (snap == null) {
        throw HostError(
          'offline_no_snapshot',
          'The data is not downloaded: this request needs a connection to Hermes',
          key: SurfacesText.hostOfflineNoSnapshot,
        );
      }
      return QueryOutcome(
        fromCache: true,
        fetchedAt: snap.fetchedAt,
        reply: {
          'dataRev': snap.dataRev,
          'fetchedAt': snap.fetchedAt.toUtc().toIso8601String(),
          'freshness': 'cached',
          'results': snap.results,
        },
      );
    } on ApiException catch (e) {
      _classify(e);
      throw _toHostError(e);
    }
  }

  void _classify(ApiException e) {
    if (e.isUnauthorized) {
      connectivity.value = Connectivity.unauthorized;
    } else {
      _markOnline();
    }
  }

  HostError _toHostError(ApiException e) {
    if (e.isUnauthorized) {
      return HostError('unauthorized', 'No access: check the token', key: SurfacesText.hostUnauthorized);
    }
    if (api is PreviewApi && e.status == 404) {
      return HostError(
        'preview_gone',
        'This build is no longer waiting for a decision. Go back to the list of apps.',
        key: SurfacesText.hostPreviewGone,
      );
    }
    if (e.isStale) {
      return HostError('stale_revision', 'The app was updated on the server', key: SurfacesText.hostStaleRevision);
    }
    if (e.status >= 500) return HostError('server_error', e.message);
    return HostError('bad_request', e.message);
  }

  String _today(String timezone) {
    // Device-local date; the key also includes the zone name, so a zone change cannot reuse a snapshot.
    final n = clock();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }
}

/// Minimal observable value (avoids depending on Flutter foundation in the logic layer).
class ValueNotifierLite<T> {
  ValueNotifierLite(this._value);
  T _value;
  final StreamController<T> _changes = StreamController<T>.broadcast();
  T get value => _value;
  set value(T v) {
    if (v == _value) return;
    _value = v;
    _changes.add(v);
  }

  Stream<T> get changes => _changes.stream;
}
