import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'api.dart';
import 'bridge.dart';
import 'bundle_store.dart';
import 'host.dart';
import 'strings.dart';

/// Most buttons that write the host answers per minute for one page: a loop in a page must not fill a table.
const int maxMutationsPerMinute = 30;

/// How long the key of a request whose outcome is unknown is kept, so an identical retry reuses it (the server then
/// answers with the first result instead of writing again). The server keeps results for a day.
const Duration mutationKeyKeep = Duration(minutes: 10);

const int _maxRememberedKeys = 64;

/// The answer to the page's `mutate` operation: a tap on a button that writes into the app's data.
///
/// The page names one of the app's reviewed mutations and gives typed arguments. Which SQL runs, whether it deletes,
/// and the words shown to the user all come from the server's manifest, never from the page. This class makes the
/// idempotency key (one per user action; a retry of an identical request after a lost answer keeps it), asks the user
/// first for anything that deletes or that the author marked, refuses in a preview, and never queues anything while
/// offline.
class MutationBridge {
  MutationBridge({
    required this.preview,
    required this.timezone,
    DateTime Function()? clock,
    String Function()? newKey,
  })  : _clock = clock ?? DateTime.now,
        _newKey = newKey ?? _randomKey;

  /// A build under review is only looked at: it never saves.
  final bool preview;
  final String Function() timezone;
  final DateTime Function() _clock;
  final String Function() _newKey;

  final Set<String> _inFlight = {};
  final Map<String, ({String key, DateTime at})> _unresolved = {};
  final List<DateTime> _recent = [];
  String? _manifestStamp;
  AppManifest? _manifest;

  HostError _error(SurfacesText key, String message, String code) => HostError(code, message, key: key);

  /// Runs one `mutate` request that the bridge gate already accepted.
  Future<Object?> handle(
    BridgeRequest req, {
    required SurfacesHost host,
    required InstalledApp app,
    required String title,
    required BuildContext context,
  }) async {
    if (preview) throw _error(SurfacesText.mutatePreviewBlocked, 'Saving is off in a preview', 'preview_blocked');
    final name = req.args['name'] as String;
    final args = Map<String, dynamic>.from(req.args['args'] as Map);
    // What identifies "the same tap": the mutation and its arguments (in a fixed order), in this app.
    final sorted = Map.fromEntries(args.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    final identity = jsonEncode({'app': app.appId, 'name': name, 'args': sorted});
    if (_inFlight.contains(identity)) throw _error(SurfacesText.mutateBusy, 'Already being saved', 'busy');
    _throttle();
    _inFlight.add(identity);
    try {
      return await _run(host, app, title, context, name, args, identity);
    } finally {
      _inFlight.remove(identity);
    }
  }

  Future<Object?> _run(SurfacesHost host, InstalledApp app, String title, BuildContext context, String name,
      Map<String, dynamic> args, String identity) async {
    // Nothing is sent without a connection, so "offline" really means nothing was saved.
    if (host.connectivity.value == Connectivity.offline) {
      throw _error(SurfacesText.mutateOffline, 'No connection', 'offline');
    }
    final info = await _info(host, app, name);
    if (info.destructive || info.confirm) {
      if (!context.mounted) return {'done': false};
      if (!await _confirm(context, title, name, info, args)) return {'done': false};
    }
    final prior = _unresolved[identity];
    final key = prior != null && _clock().difference(prior.at) < mutationKeyKeep ? prior.key : _newKey();
    _unresolved.remove(identity);
    _unresolved[identity] = (key: key, at: _clock());
    while (_unresolved.length > _maxRememberedKeys) {
      _unresolved.remove(_unresolved.keys.first);
    }
    try {
      final out = await host.api.mutate(app.appId, app.revision, name, args, key: key, timezone: timezone());
      _unresolved.remove(identity);
      return {
        'done': true,
        'rowsAffected': out['rowsAffected'] is int ? out['rowsAffected'] : 0,
        'lastInsertId': out['lastInsertId'] is int ? out['lastInsertId'] : null,
        'replayed': out['replayed'] == true,
      };
    } on OfflineException {
      // The request may have reached the server: it is not "not saved". The key stays for an identical retry.
      throw _error(SurfacesText.mutateUnknownOutcome, 'No answer from the server', 'unknown_outcome');
    } on ApiException catch (e) {
      throw _fail(e, identity);
    }
  }

  /// The refusal a page can branch on. The key is kept only where the server may have written.
  HostError _fail(ApiException e, String identity) {
    if (e.isUnauthorized) {
      _unresolved.remove(identity);
      return HostError('unauthorized', 'No access: check the token', key: SurfacesText.hostUnauthorized);
    }
    if (e.status == 409 && e.code == 'outcome_unknown') {
      return _error(SurfacesText.mutateUnknownOutcome, e.message, 'unknown_outcome');
    }
    if (e.status >= 500) {
      return _error(SurfacesText.mutateServerError, e.message, 'server_error');
    }
    _unresolved.remove(identity);
    if (e.status == 409 && e.code == null) {
      return HostError('stale_revision', 'The app was updated on the server', key: SurfacesText.hostStaleRevision);
    }
    if (e.status == 409) return _error(SurfacesText.mutateServerError, e.message, 'conflict');
    // The framework's own 404 ("Not Found") means the route does not exist: an older plugin.
    if (e.status == 404 && e.message == 'Not Found') {
      return _error(SurfacesText.mutateServerOld, 'The server cannot save changes yet', 'server_old');
    }
    if (e.status == 404) return _error(SurfacesText.mutateUnknown, e.message, 'not_found');
    // 400/422: the server refused these arguments (a missing value, a constraint). Its words, as they are.
    return HostError('rejected', e.message, key: null);
  }

  /// What the server's manifest says about [name]. Fetched once per installed version; a manifest of another
  /// revision than the one this page runs means the app was updated, which the host then installs.
  Future<MutationInfo> _info(SurfacesHost host, InstalledApp app, String name) async {
    final stamp = '${app.appId}/${app.revision}/${app.bundleId}';
    var manifest = _manifestStamp == stamp ? _manifest : null;
    if (manifest == null) {
      try {
        manifest = await host.api.manifest(app.appId);
      } on OfflineException {
        throw _error(SurfacesText.mutateOffline, 'No connection', 'offline');
      } on ApiException catch (e) {
        if (e.isUnauthorized) {
          throw HostError('unauthorized', 'No access: check the token', key: SurfacesText.hostUnauthorized);
        }
        throw _error(SurfacesText.mutateServerError, e.message, 'server_error');
      } on ManifestException catch (e) {
        throw _error(SurfacesText.mutateServerError, e.message, 'server_error');
      }
      if (manifest.revision != app.revision) {
        throw HostError('stale_revision', 'The app was updated on the server', key: SurfacesText.hostStaleRevision);
      }
      _manifest = manifest;
      _manifestStamp = stamp;
    }
    return manifest.mutation(name) ?? (throw _error(SurfacesText.mutateUnknown, 'No such action: $name', 'unknown_mutation'));
  }

  void _throttle() {
    final now = _clock();
    _recent.removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
    if (_recent.length >= maxMutationsPerMinute) {
      throw _error(SurfacesText.mutateTooMany, 'Too many changes in a short time', 'too_many_requests');
    }
    _recent.add(now);
  }

  Future<bool> _confirm(
      BuildContext context, String title, String name, MutationInfo info, Map<String, dynamic> args) async {
    final t = SurfacesStrings.of(context);
    final label = info.label ?? name.replaceAll('_', ' ');
    final destructive = info.destructive;
    final lines = [for (final e in args.entries.take(6)) '${e.key}: ${_show(e.value)}'];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t(destructive ? SurfacesText.mutateDeleteTitle : SurfacesText.mutateConfirmTitle)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t(destructive ? SurfacesText.mutateDeleteBody : SurfacesText.mutateConfirmBody,
                  {'app': title, 'label': label})),
              if (lines.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  key: const ValueKey('mutation-args'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(lines.join('\n')),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t(SurfacesText.cancel))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t(destructive ? SurfacesText.mutateDeleteAction : SurfacesText.mutateConfirmAction)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  static String _show(Object? v) {
    final text = '$v';
    return text.length > 60 ? '${text.substring(0, 60)}…' : text;
  }
}

String _randomKey() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random.secure();
  return List.generate(32, (_) => chars[random.nextInt(chars.length)]).join();
}
