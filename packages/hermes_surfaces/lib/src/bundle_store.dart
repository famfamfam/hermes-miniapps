import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'api.dart' show isValidAppId;
import 'bundle_verify.dart';
import 'preview.dart';

/// A fully installed, verified bundle version.
class InstalledApp {
  InstalledApp({
    required this.appId,
    required this.title,
    required this.bundleId,
    required this.revision,
    required this.contractHash,
    required this.epoch,
    required this.dir,
    required this.files,
    required this.entrypoint,
    required this.installedAt,
    this.preview,
  });
  final String appId;
  final String title;
  final String bundleId;
  final int revision;
  final String contractHash;
  final String epoch;
  final Directory dir;

  /// Only files listed in bundle.json are ever served.
  final Set<String> files;
  final String entrypoint;
  final DateTime installedAt;
  final PreviewIdentity? preview;
}

/// A synchronous retention handle for an installed version in a [BundleStore].
///
/// [release] is idempotent. Releasing does not delete files immediately; a later install may
/// prune the version once it is neither pinned nor the current/previous version.
class BundlePin {
  BundlePin._(this._onRelease);

  void Function()? _onRelease;

  void release() {
    final release = _onRelease;
    _onRelease = null;
    release?.call();
  }
}

/// Installed bundles on disk (ADR-009 §3): download is verified in memory, written to staging,
/// moved to an immutable version directory, and only then the pointer file is switched.
/// Every earlier step can fail without touching the version the user is running.
class BundleStore {
  BundleStore(this.root) : _rootKey = _cacheRootKey(root);

  /// `<support>/surfaces/<scope>`
  final Directory root;
  final String _rootKey;

  // Shared by all stores in this isolate, not by object identity. The whole filesystem mutation
  // is queued, including staging and pruning; unrelated roots/apps remain independent.
  static final Map<(String, String), Future<void>> _operations = {};
  static final Map<(String, String), Map<String, int>> _pins = {};
  static int _attempt = 0;

  static String _cacheRootKey(Directory root) {
    final path = p.normalize(root.absolute.path);
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  Future<T> _serialize<T>(String appId, Future<T> Function() operation) async {
    final key = (_rootKey, appId);
    final previous = _operations[key];
    final done = Completer<void>();
    _operations[key] = done.future;
    try {
      if (previous != null) await previous;
      return await operation();
    } finally {
      if (identical(_operations[key], done.future)) _operations.remove(key);
      done.complete(); // queue tails never fail, even when an operation throws
    }
  }

  /// Retains [app]'s immutable version against automatic pruning, synchronously and without I/O.
  ///
  /// Pins are reference-counted across stores sharing this root/app/bundle in the same isolate.
  /// Acquire the replacement pin before releasing the old one when changing a displayed target,
  /// and release on disposal. This does not protect against an explicit [remove] or external deletion.
  BundlePin pin(InstalledApp app) {
    _appDir(app.appId); // validate before registering a reference
    final key = (_rootKey, app.appId);
    final references = _pins.putIfAbsent(key, () => <String, int>{});
    references.update(app.bundleId, (count) => count + 1, ifAbsent: () => 1);
    return BundlePin._(() {
      final count = references[app.bundleId]!;
      if (count == 1) {
        references.remove(app.bundleId);
        if (references.isEmpty) _pins.remove(key);
      } else {
        references[app.bundleId] = count - 1;
      }
    });
  }

  bool _isVersionPinned(String appId, String versionName) =>
      _pins[(_rootKey, appId)]?.keys.any((id) => _versionName(id) == versionName) ?? false;

  /// Last line of defence for the filesystem: the id becomes a directory name, so anything that
  /// is not a plain app id (`..`, separators, case tricks) is refused before any path is built.
  Directory _appDir(String appId) {
    if (!isValidAppId(appId)) throw ArgumentError.value(appId, 'appId', 'not a valid app id');
    return Directory('${root.path}/apps/$appId');
  }

  File _pointer(String appId) => File('${_appDir(appId).path}/installed.json');
  String _versionName(String bundleId) => bundleId.replaceFirst('sha256:', '');

  Future<InstalledApp?> current(String appId) async {
    final pointer = _pointer(appId);
    try {
      if (!await pointer.exists()) return null;
      final json = jsonDecode(await pointer.readAsString()) as Map<String, dynamic>;
      return await _open(appId, json);
    } catch (_) {
      return null; // unreadable pointer: treat as not installed, never serve unknown files
    }
  }

  Future<InstalledApp?> _open(String appId, Map<String, dynamic> pointer) async {
    final bundleId = pointer['bundleId'] as String;
    final dir = Directory('${_appDir(appId).path}/versions/${_versionName(bundleId)}');
    if (!await File('${dir.path}/.complete').exists()) return null;
    final manifest = jsonDecode(await File('${dir.path}/bundle.json').readAsString()) as Map<String, dynamic>;
    final files = (manifest['files'] as List).map((e) => (e as Map<String, dynamic>)['path'] as String).toSet();
    PreviewIdentity? preview;
    if (pointer.containsKey('preview')) {
      try {
        preview = PreviewIdentity.fromJson(pointer['preview']);
      } on FormatException {
        // Legacy or damaged optional metadata must never enable approval of a cached bundle.
      }
    }
    return InstalledApp(
      appId: appId,
      title: (pointer['title'] as String?) ?? appId,
      bundleId: bundleId,
      revision: pointer['revision'] as int,
      contractHash: pointer['contractHash'] as String,
      epoch: pointer['epoch'] as String,
      dir: dir,
      files: files,
      entrypoint: manifest['entrypoint'] as String,
      installedAt: DateTime.parse(pointer['installedAt'] as String),
      preview: preview,
    );
  }

  Future<List<InstalledApp>> listInstalled() async {
    final apps = Directory('${root.path}/apps');
    if (!await apps.exists()) return [];
    final out = <InstalledApp>[];
    await for (final e in apps.list()) {
      if (e is! Directory) continue;
      final cur = await current(e.uri.pathSegments.where((s) => s.isNotEmpty).last);
      if (cur != null) out.add(cur);
    }
    return out;
  }

  /// Installs an already verified bundle. [onBeforeSwitch] lets the caller flush local state
  /// (forms) before the pointer moves; throwing from it aborts the install.
  Future<InstalledApp> install(
    String appId,
    VerifiedBundle bundle, {
    required String title,
    required int revision,
    required String contractHash,
    required String epoch,
    PreviewIdentity? preview,
    Future<void> Function()? onBeforeSwitch,
  }) async {
    _appDir(appId); // reject unsafe ids before queuing or touching disk
    return _serialize(
      appId,
      () => _install(
        appId,
        bundle,
        title: title,
        revision: revision,
        contractHash: contractHash,
        epoch: epoch,
        preview: preview,
        onBeforeSwitch: onBeforeSwitch,
      ),
    );
  }

  Future<InstalledApp> _install(
    String appId,
    VerifiedBundle bundle, {
    required String title,
    required int revision,
    required String contractHash,
    required String epoch,
    PreviewIdentity? preview,
    Future<void> Function()? onBeforeSwitch,
  }) async {
    final appDir = _appDir(appId);
    final versions = Directory('${appDir.path}/versions');
    final target = Directory('${versions.path}/${_versionName(bundle.bundleId)}');
    final attempt = '$pid-${DateTime.now().microsecondsSinceEpoch}-${_attempt++}';
    final staging = Directory('${appDir.path}/staging/$attempt');
    final tmp = File('${appDir.path}/installed.json.$attempt.tmp');
    var createdVersion = false;
    var switched = false;
    try {
      await staging.create(recursive: true);
      for (final entry in bundle.files.entries) {
        checkBundlePath(entry.key); // defence in depth: verifyBundle already did
        final file = File('${staging.path}/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      await File('${staging.path}/bundle.json').writeAsString(jsonEncode(bundle.manifest), flush: true);
      await File('${staging.path}/.complete').writeAsString('ok', flush: true);

      await versions.create(recursive: true);
      if (await target.exists()) {
        await staging.delete(recursive: true); // same digest already installed
      } else {
        await staging.rename(target.path);
        createdVersion = true;
      }
      await onBeforeSwitch?.call();

      final previous = await current(appId);
      final pointer = {
        'title': title,
        'bundleId': bundle.bundleId,
        'revision': revision,
        'contractHash': contractHash,
        'epoch': epoch,
        'installedAt': DateTime.now().toUtc().toIso8601String(),
        'previous': previous?.bundleId,
        if (preview != null) 'preview': preview.toJson(),
      };
      await tmp.writeAsString(jsonEncode(pointer), flush: true);
      await tmp.rename(_pointer(appId).path); // single atomic switch
      switched = true;
      await _prune(appId, keep: {bundle.bundleId, if (previous != null) previous.bundleId});
      return (await current(appId))!;
    } catch (_) {
      // Before the switch, only this attempt's files may be removed. A pinned immutable version
      // must survive even an aborted install (e.g. a caller retained it in onBeforeSwitch).
      if (await staging.exists()) await staging.delete(recursive: true);
      if (await tmp.exists()) await tmp.delete();
      if (!switched &&
          createdVersion &&
          await target.exists() &&
          !_isVersionPinned(appId, _versionName(bundle.bundleId))) {
        await target.delete(recursive: true);
      }
      final stagingRoot = Directory('${appDir.path}/staging');
      if (await stagingRoot.exists() && await stagingRoot.list().isEmpty) await stagingRoot.delete();
      rethrow;
    }
  }

  Future<void> _prune(String appId, {required Set<String> keep}) async {
    final versions = Directory('${_appDir(appId).path}/versions');
    if (!await versions.exists()) return;
    final keepNames = {...keep.map(_versionName), ...?_pins[(_rootKey, appId)]?.keys.map(_versionName)};
    await for (final e in versions.list()) {
      if (e is! Directory) continue;
      final name = p.basename(e.path);
      // Directory enumeration yields to callers: recheck live pins immediately before deleting,
      // rather than relying only on the snapshot taken when pruning started.
      if (!keepNames.contains(name) && !_isVersionPinned(appId, name)) {
        await e.delete(recursive: true);
      }
    }
    final staging = Directory('${_appDir(appId).path}/staging');
    if (await staging.exists()) await staging.delete(recursive: true);
  }

  /// Bytes of a listed file, or null. Unlisted paths are never read from disk.
  Future<Uint8List?> read(InstalledApp app, String relativePath) async {
    if (!app.files.contains(relativePath)) return null;
    return File('${app.dir.path}/$relativePath').readAsBytes();
  }

  /// Explicit uninstall. Unlike automatic pruning, this also removes pinned versions.
  Future<void> remove(String appId) async {
    final d = _appDir(appId);
    return _serialize(appId, () async {
      if (await d.exists()) await d.delete(recursive: true);
    });
  }
}
