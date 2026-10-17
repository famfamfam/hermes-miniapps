import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';

import 'apps_widgets.dart';
import 'bound_api.dart';
import 'host_bridge.dart';

/// Apps catalogue and native Surface routes inside the host's existing MaterialApp/Navigator.
/// No pairing, key generation, settings persistence, cache clearing or diagnostic file writes.
class AppsModule extends StatefulWidget {
  const AppsModule({
    super.key,
    required this.bridge,
    this.title,
    this.embedded = false,
    this.hostFactory,
    this.previewHostFactory,
    this.surfacePageBuilder,
    this.onDiag,
    this.appBarActions = const [],
    this.onConfigure,
    this.onPasteCode,
    this.hostNotice,
    this.hostBusy = false,
    this.autoSync = true,
    this.showChat = true,
    this.active = true,
  });

  final HostBridge bridge;

  /// False while the host keeps this module mounted but out of sight (a tab that is not selected):
  /// nothing is polled then, and the first moment it is visible again reads the server quietly.
  final bool active;

  /// Offer "Open chat" in the embedded header. A host whose navigation already has Chat one tap
  /// away (a tab) turns it off; the standalone layout and the app page always keep it.
  final bool showChat;

  /// Keep the catalogue in step with the server without a tap: re-read it every half minute and
  /// download new and updated apps in the background. Off, every app is fetched when it is opened.
  final bool autoSync;

  /// Overrides the localized default title (non-embedded layout only).
  final String? title;

  /// Omit the module's app bar when the native shell already provides one.
  /// A native Chat entry remains available in either layout, even without a connection.
  final bool embedded;
  final HostFactory? hostFactory;
  final HostFactory? previewHostFactory;
  final SurfacePageBuilder? surfacePageBuilder;
  final void Function(String appId, DiagEntry entry)? onDiag;
  final List<Widget> appBarActions;

  /// Optional host hook (presentation only): opens the host's explicit configuration. When set, the
  /// header offers "Set up Surfaces" and the unconfigured state becomes a short onboarding card.
  final VoidCallback? onConfigure;

  /// Optional host hook: opens the configuration already on the "paste connection code" step. When set,
  /// the onboarding and "no access" cards lead with it and offer [onConfigure] as the manual way.
  final VoidCallback? onPasteCode;

  /// Optional host reason why there is no connection (changed context, failed read…), as a key of the
  /// shared string layer so it is shown in the viewer's language. Null means "not configured yet".
  final SurfacesText? hostNotice;

  /// The host is still reading its saved connection: show "connecting", not "not configured".
  final bool hostBusy;

  @override
  State<AppsModule> createState() => _AppsModuleState();
}

/// What the single status chip says. [dataAt] is when the shown data was last fetched (offline).
enum _LinkKind { unconfigured, address, unavailable, connecting, online, incompatible, offline, unauthorized, failed }

class _Link {
  const _Link(this.kind, [this.dataAt]);
  final _LinkKind kind;
  final DateTime? dataAt;
}

/// A published app that could not be downloaded/opened. Only valid for the revision it failed at.
class _Failure {
  const _Failure(this.message, this.revision);
  final String message;
  final int? revision;
}

enum _Body { list, connecting, setup, standalone, notice, address, unauthorized, failed, offlineEmpty, empty }

/// Touch targets stay at 48dp whatever the host theme's tap-target size says.
const _target = BoxConstraints(minWidth: 48, minHeight: 48);
const _touch = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(64, 48)));

class _Session {
  _Session(this.bridge, this.connection, this.generation);
  final HostBridge bridge;
  final SurfacesConnection connection;
  final int generation;
  final ValueNotifier<bool> active = ValueNotifier(true);
  final List<SurfacesApi> _apis = [];
  SurfacesHost? host;
  Future<SurfacesHost?>? previewHost;
  Directory? supportRoot;
  ApproverKey? key;
  bool keyLoading = true;
  bool keyFailed = false;
  bool reviews = false;
  bool appDelete = false; // the server can delete apps (an older plugin cannot)
  bool paired = false;
  bool refreshing = false;
  bool readingPreviews = false;
  bool syncing = false; // the background download loop of this session is running
  DateTime? lastOnline;
  Timer? timer;

  bool get current => active.value && sameConnection(connection, bridge.activeConnection.value);

  void close() {
    if (!active.value) return;
    active.value = false;
    timer?.cancel();
    for (final api in _apis) {
      try {
        api.close();
      } catch (_) {
        // A host transport's close failure must not keep other Apps clients alive or block chat.
      }
    }
    _apis.clear();
  }
}

class _AppsModuleState extends State<AppsModule> {
  _Session? _session;
  int _generation = 0;
  List<_Row> _rows = [];
  List<PreviewSummary> _previews = [];
  bool _busy = false;
  _Link _link = const _Link(_LinkKind.unconfigured);
  SurfacesText? _reviewStatus;

  /// The viewer's language, refreshed whenever the ambient Localizations change; also used by async
  /// completions that have no BuildContext of their own.
  SurfacesStrings _t = SurfacesStrings.forLanguage(null);

  /// Presentation only: which card is being opened (`a:ID` published, `p:ID` preview) and why a
  /// published app last failed to open. Never consulted by any guard.
  String? _opening;
  final Map<String, _Failure> _failures = {};

  /// Apps being downloaded in the background right now (presentation only).
  final Set<String> _syncing = {};

  /// app id -> the server revision whose background download failed; not retried until the revision changes.
  final Map<String, int> _syncFailed = {};

  bool _current(_Session s) => mounted && identical(_session, s) && s.generation == _generation && s.current;

  @override
  void initState() {
    super.initState();
    widget.bridge.activeConnection.addListener(_bindingChanged);
    _replaceSession();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _t = SurfacesStrings.of(context);
  }

  @override
  void didUpdateWidget(AppsModule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bridge, widget.bridge)) {
      oldWidget.bridge.activeConnection.removeListener(_bindingChanged);
      widget.bridge.activeConnection.addListener(_bindingChanged);
      _replaceSession();
    } else if (widget.active && !oldWidget.active) {
      final s = _session;
      if (s != null && _current(s) && s.host != null && !_busy && !s.refreshing) {
        unawaited(_refresh(s, refreshIdentity: false, quiet: true));
      }
    }
  }

  @override
  void dispose() {
    widget.bridge.activeConnection.removeListener(_bindingChanged);
    _generation++;
    _session?.close();
    super.dispose();
  }

  void _bindingChanged() {
    if (sameConnection(_session?.connection, widget.bridge.activeConnection.value)) return;
    // Synchronous invalidation: no old async completion can publish state or start a request,
    // including an A -> B -> A switch before the next frame.
    setState(_replaceSession);
  }

  void _replaceSession() {
    _generation++;
    _session?.close();
    _session = null;
    _rows = [];
    _previews = [];
    _reviewStatus = null;
    _busy = false;
    _opening = null;
    _failures.clear();
    _syncing.clear();
    _syncFailed.clear();
    final connection = widget.bridge.activeConnection.value;
    if (connection == null || connection.config.token.isEmpty) {
      _link = const _Link(_LinkKind.unconfigured);
      return;
    }
    try {
      connection.scope;
    } on ArgumentError {
      _link = const _Link(_LinkKind.address);
      return;
    }
    final s = _Session(widget.bridge, connection, _generation);
    _session = s;
    _busy = true;
    _link = const _Link(_LinkKind.connecting);
    unawaited(_initialize(s));
  }

  Future<void> _initialize(_Session s) async {
    try {
      s.supportRoot = await s.bridge.applicationSupportDirectory();
      if (!_current(s)) return;
      // Key loading cannot block the read-only catalogue or preview listing.
      unawaited(_loadKey(s));
      s.host = await _createHost(s, preview: false);
      if (!_current(s) || s.host == null) return;
      await _refresh(s, alreadyBusy: true, refreshIdentity: false);
      if (!_current(s)) return;
      var ticks = 0;
      s.timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!_current(s) || _busy || s.refreshing || !widget.active) return;
        // A catalogue that came up offline (first request lost, VPN settling) recovers by itself, and an
        // online one is re-read every half minute, so new apps and new revisions arrive without a tap.
        final lost = _link.kind == _LinkKind.offline || _link.kind == _LinkKind.unavailable;
        final due = widget.autoSync && _link.kind == _LinkKind.online && ++ticks % 6 == 0;
        // Always quiet: a retry against an unreachable server can take the whole request timeout, and the
        // cards, which still open from the saved copy, must not be disabled for that time.
        unawaited(lost || due ? _refresh(s, refreshIdentity: false, quiet: true) : _refreshPreviews(s));
      });
    } catch (_) {
      if (_current(s)) {
        setState(() {
          _busy = false;
          _link = const _Link(_LinkKind.unavailable);
        });
      }
    }
  }

  Future<void> _loadKey(_Session s) async {
    // This callback is the only identity source. Never loadOrCreate/pair in the module.
    try {
      final key = await s.bridge.loadApproverKey();
      if (!_current(s)) return;
      s.key = key;
    } catch (_) {
      if (!_current(s)) return;
      s.keyFailed = true;
    }
    if (_current(s)) {
      setState(() {
        s.keyLoading = false;
        _reviewStatus = _reviewDisabled(s);
      });
    }
  }

  Future<SurfacesHost?> _createHost(_Session s, {required bool preview}) async {
    final original = s.connection;
    final connection = preview
        ? SurfacesConnection(
            config: original.config.forPreview(),
            strictNetworkBlock: original.strictNetworkBlock,
            sealNetwork: original.sealNetwork,
          )
        : original;
    final root = Directory('${s.supportRoot!.path}/surfaces/${connection.scope}');
    final factory = preview ? (widget.previewHostFactory ?? widget.hostFactory) : widget.hostFactory;
    final SurfacesHost raw;
    if (factory != null) {
      raw = await factory(connection, root, preview);
    } else {
      if (!_current(s)) return null;
      final client = s.bridge.createSurfacesClient(connection);
      final api = preview
          ? PreviewApi(connection.config, client: client)
          : SurfacesApi(connection.config, client: client);
      raw = SurfacesHost(api: api, bundles: BundleStore(root), snapshots: SnapshotCache(root));
    }
    if (!_current(s)) {
      raw.api.close();
      return null;
    }
    final api = bindApi(raw.api, () => _current(s));
    s._apis.add(api);
    return SurfacesHost(api: api, bundles: raw.bundles, snapshots: raw.snapshots, clock: raw.clock);
  }

  Future<SurfacesHost?> _getPreviewHost(_Session s) async {
    final pending = s.previewHost ??= _createHost(s, preview: true);
    try {
      final host = await pending;
      if (host == null && identical(s.previewHost, pending)) s.previewHost = null;
      return host;
    } catch (_) {
      if (identical(s.previewHost, pending)) s.previewHost = null;
      rethrow;
    }
  }

  SurfacesText? _reviewDisabled(_Session s) {
    if (!s.reviews) return null;
    if (s.keyLoading) return SurfacesText.reviewKeyLoading;
    if (s.keyFailed) return SurfacesText.reviewKeyError;
    if (s.key == null) return SurfacesText.reviewNoKey;
    if (!s.paired) return SurfacesText.reviewNotPaired;
    return null;
  }

  Future<void> _refresh(
    _Session s, {
    bool alreadyBusy = false,
    bool refreshIdentity = true,
    bool quiet = false,
  }) async {
    final host = s.host;
    if (!_current(s) || host == null || s.refreshing || s.readingPreviews || (_busy && !alreadyBusy)) return;
    if (refreshIdentity && !s.keyLoading && (s.key == null || s.keyFailed)) {
      s.keyLoading = true;
      s.keyFailed = false;
      unawaited(_loadKey(s));
    }
    s.refreshing = true;
    // A quiet (timer) refresh keeps the screen as it is: no "refreshing" chip, no disabled cards.
    if (!quiet) setState(() => _busy = true);
    var installed = <String, InstalledApp>{};
    var rows = <_Row>[];
    _Link link;
    try {
      installed = {for (final app in await host.bundles.listInstalled()) app.appId: app};
      if (!_current(s)) return;
      final hello = await host.api.hello(sdkMajor: supportedSdkMajors.first, timezone: 'UTC');
      if (!_current(s)) return;
      final apps = await host.api.listApps();
      if (!_current(s)) return;
      rows = [for (final app in apps) _Row(app.appId, app.title, app.revision, installed[app.appId])];
      if (hello['compatible'] == true) {
        // The server is the source of truth: an app deleted there (from this or another phone, or by the
        // administrator) must not live on in this phone's offline list.
        final known = {for (final app in apps) app.appId};
        for (final orphan in [for (final id in installed.keys) if (!known.contains(id)) id]) {
          try {
            await host.bundles.remove(orphan);
            installed.remove(orphan);
          } catch (_) {
            // Disk trouble: the copy is retried at the next refresh and hidden from the online list meanwhile.
          }
        }
      }
      host.connectivity.value = Connectivity.online;
      s.lastOnline = host.clock();
      link = _Link(hello['compatible'] == true ? _LinkKind.online : _LinkKind.incompatible);
      final health = await host.api.health();
      if (!_current(s)) return;
      s.reviews = health['reviews'] == true;
      s.appDelete = health['appDelete'] == true;
      s.paired = health['approverPaired'] == true;
      await _refreshPreviews(s, whileBusy: true);
      if (host.connectivity.value == Connectivity.unauthorized) {
        rows = [];
        link = const _Link(_LinkKind.unauthorized);
      } else if (host.connectivity.value == Connectivity.offline) {
        rows = [for (final app in installed.values) _Row(app.appId, app.title, app.revision, app)];
        link = _offlineLink(s, installed.values);
      }
    } on OfflineException {
      host.connectivity.value = Connectivity.offline;
      rows = [for (final app in installed.values) _Row(app.appId, app.title, app.revision, app)];
      link = _offlineLink(s, installed.values);
      if (_current(s)) _previews = [];
    } on ApiException catch (e) {
      host.connectivity.value = e.isUnauthorized ? Connectivity.unauthorized : Connectivity.online;
      // Never label cached or previously fetched data as live after credential rejection.
      rows = e.isUnauthorized
          ? []
          : [for (final app in installed.values) _Row(app.appId, app.title, app.revision, app)];
      link = _Link(e.isUnauthorized ? _LinkKind.unauthorized : _LinkKind.failed);
      if (_current(s)) _previews = [];
    } catch (_) {
      link = const _Link(_LinkKind.unavailable);
      rows = [for (final app in installed.values) _Row(app.appId, app.title, app.revision, app)];
      if (_current(s)) _previews = [];
    } finally {
      s.refreshing = false;
    }
    if (!_current(s)) return;
    setState(() {
      _rows = rows;
      _link = link;
      _reviewStatus = _reviewDisabled(s);
      if (!quiet) _busy = false;
    });
    if (widget.autoSync && link.kind == _LinkKind.online) unawaited(_syncApps(s));
  }

  /// Downloads new and updated apps in the background, one at a time, so every card is ready to open
  /// (and to open offline) without a tap. A failure leaves the card as it was; tapping it retries.
  Future<void> _syncApps(_Session s) async {
    if (s.syncing) return;
    s.syncing = true;
    try {
      for (final row in List<_Row>.of(_rows)) {
        final host = s.host;
        if (!_current(s) || host == null) return;
        final installed = row.installed;
        if (installed != null && installed.revision >= row.revision) continue;
        // A revision that failed once is not retried on the timer: it would re-download a bad bundle every
        // half minute. A newer revision, or a tap on the card, tries again.
        if (_syncFailed[row.appId] == row.revision) continue;
        setState(() => _syncing.add(row.appId));
        try {
          final app = await host.ensureInstalled(row.appId);
          if (!_current(s)) return;
          // ensureInstalled keeps the old version when the new one is refused: still behind means it failed.
          if (app.revision < row.revision) _syncFailed[row.appId] = row.revision;
          setState(() {
            _rows = [for (final r in _rows) r.appId == row.appId ? _Row(r.appId, r.title, r.revision, app) : r];
          });
        } catch (_) {
          // Not downloaded: the card keeps its "needs download" state and its normal retry.
          _syncFailed[row.appId] = row.revision;
        } finally {
          if (mounted) setState(() => _syncing.remove(row.appId));
        }
      }
    } finally {
      s.syncing = false;
    }
  }

  /// "Data from" is the last successful listing of this session, else the newest installed bundle.
  _Link _offlineLink(_Session s, Iterable<InstalledApp> installed) {
    var at = s.lastOnline;
    if (at == null) {
      for (final app in installed) {
        if (at == null || app.installedAt.isAfter(at)) at = app.installedAt;
      }
    }
    return _Link(_LinkKind.offline, at);
  }

  Future<void> _refreshPreviews(_Session s, {bool whileBusy = false}) async {
    final host = s.host;
    if (!_current(s) || host == null || s.readingPreviews || (_busy && !whileBusy)) return;
    if (!s.reviews) {
      setState(() => _previews = []);
      return;
    }
    s.readingPreviews = true;
    try {
      // Reading does not require an approver key and performs no pairing/writes.
      final list = await host.api.previews();
      if (_current(s)) setState(() => _previews = list);
    } on OfflineException {
      if (_current(s)) {
        host.connectivity.value = Connectivity.offline;
        setState(() {
          _previews = [];
          _rows = [
            for (final row in _rows)
              if (row.installed != null) _Row(row.appId, row.installed!.title, row.installed!.revision, row.installed),
          ];
          _link = _offlineLink(s, [for (final row in _rows) ?row.installed]);
        });
      }
    } on ApiException catch (e) {
      if (_current(s)) {
        host.connectivity.value = e.isUnauthorized ? Connectivity.unauthorized : Connectivity.online;
        setState(() {
          _previews = [];
          if (e.isUnauthorized) {
            _rows = [];
            _link = const _Link(_LinkKind.unauthorized);
          }
        });
      }
    } catch (_) {
      if (_current(s)) setState(() => _previews = []);
    } finally {
      s.readingPreviews = false;
    }
  }

  Future<String?> _approve(_Session s, InstalledApp shown) async {
    if (!_current(s)) return _t(SurfacesText.reopenPreview);
    if (!s.reviews) return _t(SurfacesText.reviewUnavailable);
    final disabled = _reviewDisabled(s);
    if (disabled != null || s.key == null) return _t(disabled ?? SurfacesText.reviewNoKeyShort);
    try {
      final revision = await ReviewClient(s.host!.api, s.key!).approve(shown);
      if (!_current(s)) return _t(SurfacesText.decisionNotConfirmed);
      _toast(_t(SurfacesText.publishedRevision, {'revision': revision}));
      return null;
    } on ApprovalFailure catch (e) {
      return _t.describe(e.key, e.message);
    } on ApiException catch (e) {
      return e.status == 422 ? _t(SurfacesText.serverRejectedApproval, {'detail': e.message}) : e.message;
    } on OfflineException {
      return _t(SurfacesText.noConnection);
    } catch (_) {
      return _t(SurfacesText.approvalFailed);
    }
  }

  Future<void> _reject(_Session s, InstalledApp shown) async {
    ApprovalFailure refusal(SurfacesText key) => ApprovalFailure(_t(key), key: key);
    if (!_current(s)) throw refusal(SurfacesText.reopenPreview);
    if (!s.reviews) throw refusal(SurfacesText.reviewUnavailable);
    final disabled = _reviewDisabled(s);
    if (disabled != null || s.key == null) throw refusal(disabled ?? SurfacesText.reviewNoKeyShort);
    await ReviewClient(s.host!.api, s.key!).reject(shown);
    if (!_current(s)) throw refusal(SurfacesText.decisionNotConfirmed);
  }

  /// Deleting is decided by this phone's signature, like publishing. The app moves to the server's trash
  /// (30 days); here its downloaded copy goes at once and the row disappears without waiting for the list.
  Future<void> _delete(_Row row) async {
    final s = _session;
    if (s == null || !_current(s) || _busy) return;
    if (!s.appDelete) {
      _toast(_t(SurfacesText.deleteUnsupported));
      return;
    }
    final disabled = _reviewDisabled(s);
    if (disabled != null || s.key == null) {
      _toast(_t(disabled ?? SurfacesText.reviewNoKeyShort));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('apps-delete-dialog'),
        title: Text(_t(SurfacesText.deleteDialogTitle, {'title': row.title})),
        content: Text(_t(SurfacesText.deleteDialogBody)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(_t(SurfacesText.cancel))),
          FilledButton(
            key: const ValueKey('apps-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t(SurfacesText.deleteApp)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_current(s) || _busy) return;
    setState(() => _busy = true);
    var deleted = false;
    try {
      await ReviewClient(s.host!.api, s.key!).deleteApp(row.appId, revision: row.revision);
      deleted = true;
      try {
        await s.host!.bundles.remove(row.appId);
      } catch (_) {
        // The server no longer has the app; the next online refresh removes a copy that is still here.
      }
      if (_current(s)) {
        setState(() {
          _rows = [for (final r in _rows) if (r.appId != row.appId) r];
          _failures.remove(row.appId);
          _syncFailed.remove(row.appId);
        });
        _toast(_t(SurfacesText.appDeleted, {'title': row.title}));
      }
    } on ApprovalFailure catch (e) {
      _toast(_t.describe(e.key, e.message));
    } on ApiException catch (e) {
      _toast(switch (e.status) {
        404 || 405 => _t(SurfacesText.deleteUnsupported),
        409 || 422 => _t(SurfacesText.deleteRejected, {'detail': e.message}),
        _ => e.message,
      });
    } on OfflineException {
      _toast(_t(SurfacesText.noConnection));
    } catch (_) {
      _toast(_t(SurfacesText.deleteFailed));
    } finally {
      if (mounted && _current(s)) setState(() => _busy = false);
    }
    if (deleted && mounted && _current(s)) unawaited(_refresh(s, quiet: true));
  }

  Future<void> _open(String appId, String title, {bool preview = false}) async {
    final s = _session;
    if (s == null || !_current(s) || _busy) return;
    setState(() {
      _busy = true;
      _opening = '${preview ? 'p' : 'a'}:$appId';
      if (!preview) {
        _failures.remove(appId);
        _syncFailed.remove(appId); // a tap is an explicit retry
      }
    });
    try {
      final host = preview ? await _getPreviewHost(s) : s.host;
      if (!_current(s) || host == null) return;
      final app = await host.ensureInstalled(appId);
      if (!mounted || !_current(s)) return;
      final connection = preview
          ? SurfacesConnection(
              config: s.connection.config.forPreview(),
              strictNetworkBlock: s.connection.strictNetworkBlock,
              sealNetwork: s.connection.sealNetwork,
            )
          : s.connection;
      final request = SurfacePageRequest(
        connection: connection,
        host: host,
        app: app,
        title: title,
        openChat: () async {
          if (_current(s)) await s.bridge.openChat();
        },
        fileActions: s.bridge.fileActions,
        sendToHermes: s.bridge.sendToHermes == null
            ? null
            : (text) async => _current(s) && await (s.bridge.sendToHermes?.call(text) ?? Future.value(false)),
        onDiag: widget.onDiag == null
            ? null
            : (entry) {
                if (_current(s)) widget.onDiag!(preview ? 'preview_$appId' : appId, entry);
              },
        preview: preview
            ? PreviewActions(approve: (shown) => _approve(s, shown), reject: (shown) => _reject(s, shown))
            : null,
      );
      final result = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => _BoundSurfacePage(session: s, request: request, builder: widget.surfacePageBuilder),
        ),
      );
      if (_current(s) && preview && result == false) _toast(_t(SurfacesText.previewRejected));
    } on HostError catch (e) {
      if (_current(s)) _openFailed(appId, preview, _t.describe(e.key, e.message));
    } on BundleException catch (e) {
      if (_current(s)) _openFailed(appId, preview, _t(SurfacesText.bundleRejected, {'detail': e.message}));
    } on ManifestException catch (e) {
      if (_current(s)) _openFailed(appId, preview, _t(SurfacesText.manifestRejected, {'detail': e.message}));
    } on ApiException catch (e) {
      if (_current(s)) {
        final withdrawn = e.status == 404 && preview;
        final text = withdrawn
            ? _t(SurfacesText.previewWithdrawn)
            : _t(SurfacesText.serverError, {'detail': e.message});
        _openFailed(appId, preview, text);
      }
    } on OfflineException {
      if (_current(s)) _openFailed(appId, preview, _t(SurfacesText.noConnection));
    } catch (_) {
      if (_current(s)) _openFailed(appId, preview, _t(SurfacesText.openFailed));
    } finally {
      if (_current(s)) {
        setState(() {
          _busy = false;
          _opening = null;
        });
        await _refresh(s);
      }
    }
  }

  /// Toast as before, and remember why a PUBLISHED app failed so its card can offer a retry.
  void _openFailed(String appId, bool preview, String message) {
    if (!preview) {
      int? revision;
      for (final row in _rows) {
        if (row.appId == appId) revision = row.revision;
      }
      _failures[appId] = _Failure(message, revision);
    }
    _toast(message);
  }

  void _toast(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _chat() async {
    final bridge = widget.bridge;
    final binding = bridge.activeConnection.value;
    if (mounted && sameConnection(binding, bridge.activeConnection.value)) await bridge.openChat();
  }

  // -- presentation ------------------------------------------------------------------------------
  // Everything below only reads state; no guard, lease, ownership or request path lives here.

  /// "12:19" today, "14.10 12:19" otherwise (device-local, no intl dependency).
  String _when(DateTime at) {
    final local = at.toLocal();
    final now = (_session?.host?.clock ?? DateTime.now)().toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(local.hour)}:${two(local.minute)}';
    final today = local.year == now.year && local.month == now.month && local.day == now.day;
    return today ? time : '${two(local.day)}.${two(local.month)} $time';
  }

  _Body _bodyKind() {
    if (_session == null) {
      if (_link.kind == _LinkKind.address) return _Body.address;
      if (widget.hostBusy) return _Body.connecting;
      if (widget.hostNotice != null) return _Body.notice;
      return widget.onConfigure != null ? _Body.setup : _Body.standalone;
    }
    if (_rows.isNotEmpty || _previews.isNotEmpty) return _Body.list;
    return switch (_link.kind) {
      _LinkKind.connecting => _Body.connecting,
      _LinkKind.unauthorized => _Body.unauthorized,
      _LinkKind.failed || _LinkKind.unavailable || _LinkKind.incompatible => _Body.failed,
      _LinkKind.offline => _Body.offlineEmpty,
      _ => _Body.empty,
    };
  }

  /// The single status: icon, short text, tone. Detail and actions live in the body card.
  (IconData, String, AppsTone) _chip() {
    if (_session == null) {
      if (_link.kind == _LinkKind.address) return (Icons.link_off, _t(SurfacesText.chipBadAddress), AppsTone.error);
      if (widget.hostBusy) return (Icons.sync, _t(SurfacesText.chipConnecting), AppsTone.neutral);
      if (widget.hostNotice != null) {
        return (Icons.error_outline, _t(SurfacesText.chipHostUnavailable), AppsTone.warn);
      }
      return (Icons.settings_suggest_outlined, _t(SurfacesText.chipNotConfigured), AppsTone.neutral);
    }
    if (_busy && _opening == null) {
      final first = _link.kind == _LinkKind.connecting;
      final label = first ? SurfacesText.chipConnecting : SurfacesText.chipRefreshing;
      return (Icons.sync, _t(label), AppsTone.neutral);
    }
    final at = _link.dataAt;
    return switch (_link.kind) {
      _LinkKind.online => (Icons.cloud_done_outlined, _t(SurfacesText.chipOnline), AppsTone.ok),
      _LinkKind.offline => (
        Icons.cloud_off_outlined,
        at == null ? _t(SurfacesText.chipOffline) : _t(SurfacesText.chipOfflineSince, {'time': _when(at)}),
        AppsTone.warn,
      ),
      _LinkKind.unauthorized => (Icons.lock_outline, _t(SurfacesText.chipTokenRejected), AppsTone.error),
      _LinkKind.incompatible => (Icons.sync_problem_outlined, _t(SurfacesText.chipIncompatible), AppsTone.error),
      _LinkKind.failed => (Icons.error_outline, _t(SurfacesText.chipError), AppsTone.error),
      _LinkKind.unavailable => (Icons.cloud_off_outlined, _t(SurfacesText.chipUnavailable), AppsTone.error),
      _ => (Icons.sync, _t(SurfacesText.chipConnecting), AppsTone.neutral),
    };
  }

  Future<void> _pullRefresh() async {
    final s = _session;
    if (s != null) await _refresh(s);
  }

  Widget _refreshAction({required bool labelled, required bool enabled}) {
    final onPressed = enabled ? () => _refresh(_session!) : null;
    if (!labelled) {
      return IconButton(
        tooltip: _t(SurfacesText.refresh),
        constraints: _target,
        icon: const Icon(Icons.refresh),
        onPressed: onPressed,
      );
    }
    return Tooltip(
      message: _t(SurfacesText.refresh),
      excludeFromSemantics: true,
      child: TextButton.icon(
        style: _touch,
        onPressed: onPressed,
        icon: const Icon(Icons.refresh),
        label: Text(_t(SurfacesText.refresh)),
      ),
    );
  }

  Widget _settingsAction({required bool labelled}) {
    const icon = Icon(Icons.settings_outlined);
    if (!labelled) {
      return IconButton(
        tooltip: _t(SurfacesText.configureSurfaces),
        constraints: _target,
        icon: icon,
        onPressed: widget.onConfigure,
      );
    }
    return Tooltip(
      message: _t(SurfacesText.configureSurfaces),
      excludeFromSemantics: true,
      child: TextButton.icon(
        style: _touch,
        onPressed: widget.onConfigure,
        icon: icon,
        label: Text(_t(SurfacesText.settings)),
      ),
    );
  }

  Widget _configureButton({required bool primary}) {
    const icon = Icon(Icons.settings_outlined);
    final label = Text(_t(SurfacesText.configureSurfaces));
    return Tooltip(
      message: _t(SurfacesText.configureSurfaces),
      excludeFromSemantics: true,
      child: primary
          ? FilledButton.icon(style: _touch, onPressed: widget.onConfigure, icon: icon, label: label)
          : OutlinedButton.icon(style: _touch, onPressed: widget.onConfigure, icon: icon, label: label),
    );
  }

  /// The main way in: copy the line Hermes sent and paste it. Offered when the host supports it.
  Widget _pasteCodeButton() => FilledButton.icon(
    key: const ValueKey('apps-paste-code'),
    style: _touch,
    onPressed: widget.onPasteCode,
    icon: const Icon(Icons.content_paste_go),
    label: Text(_t(SurfacesText.pasteCode)),
  );

  Widget _retryButton() => OutlinedButton.icon(
    style: _touch,
    onPressed: !_busy && _session?.host != null ? () => _refresh(_session!) : null,
    icon: const Icon(Icons.refresh),
    label: Text(_t(SurfacesText.retry)),
  );

  /// One row: Chat is always reachable; refresh and settings get a label only where it fits.
  Widget _header({required bool showRefresh, required bool canRefresh, required bool showSettings}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth / (MediaQuery.textScalerOf(context).scale(14) / 14);
        final labelSettings = room >= 330;
        final labelRefresh = room >= 440;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: widget.showChat
                    ? Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FilledButton.tonalIcon(
                          style: _touch,
                          onPressed: _chat,
                          icon: const Icon(Icons.chat_outlined),
                          label: Text(_t(SurfacesText.openChat)),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              if (showRefresh) _refreshAction(labelled: labelRefresh, enabled: canRefresh),
              if (showSettings) _settingsAction(labelled: labelSettings),
            ],
          ),
        );
      },
    );
  }

  Widget _spinner() => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5));

  Widget _previewTile(PreviewSummary p) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: cs.tertiaryContainer,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        iconColor: cs.onTertiaryContainer,
        textColor: cs.onTertiaryContainer,
        leading: const Icon(Icons.rate_review_outlined),
        title: Text(p.title),
        subtitle: Text(
          p.isNew ? _t(SurfacesText.previewNew) : _t(SurfacesText.previewChange, {'revision': p.baseRevision}),
        ),
        trailing: _opening == 'p:${p.appId}' ? _spinner() : const Icon(Icons.chevron_right),
        onTap: _busy ? null : () => _open(p.appId, p.title, preview: true),
      ),
    );
  }

  Widget _appTile(_Row row) {
    final theme = Theme.of(context);
    final installed = row.installed;
    final failure = _failures[row.appId];
    Widget subtitle;
    Widget trailing = const Icon(Icons.chevron_right);
    if (_opening == 'a:${row.appId}' || _syncing.contains(row.appId)) {
      final syncing = _opening != 'a:${row.appId}';
      subtitle = Text(_t(installed == null || syncing ? SurfacesText.appDownloading : SurfacesText.appOpening));
      trailing = _spinner();
    } else if (failure != null && failure.revision == row.revision) {
      // A failure belongs to the revision it happened at; a newer server revision starts clean.
      subtitle = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(failure.message, style: TextStyle(color: theme.colorScheme.error)),
          Text(_t(SurfacesText.tapToRetry)),
        ],
      );
      trailing = const Icon(Icons.refresh);
    } else if (installed == null) {
      subtitle = Text(_t(SurfacesText.appNeedsDownload));
      trailing = const Icon(Icons.cloud_download_outlined);
    } else if (installed.revision < row.revision) {
      subtitle = Text(_t(SurfacesText.appUpdate, {'revision': row.revision}));
    } else {
      subtitle = Text(_t(SurfacesText.appReady));
    }
    // Deleting needs the server (and the paired device's signature), so the menu exists only while online.
    final menu = _link.kind == _LinkKind.online
        ? PopupMenuButton<String>(
            key: ValueKey('app-menu-${row.appId}'),
            enabled: !_busy,
            onSelected: (value) {
              if (value == 'delete') unawaited(_delete(row));
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'delete',
                child: Text(_t(SurfacesText.deleteApp), style: TextStyle(color: theme.colorScheme.error)),
              ),
            ],
          )
        : null;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: AppAvatar(appId: row.appId, title: row.title),
        title: Text(row.title),
        subtitle: subtitle,
        trailing: menu == null ? trailing : Row(mainAxisSize: MainAxisSize.min, children: [trailing, menu]),
        onTap: _busy ? null : () => _open(row.appId, row.title),
      ),
    );
  }

  List<Widget> _listChildren() {
    final theme = Theme.of(context);
    return [
      if (_previews.isNotEmpty) ...[
        // Unchanged in meaning: these builds wait for the owner's decision. Just easier to see.
        Semantics(
          header: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(Icons.rate_review_outlined, size: 20, color: theme.colorScheme.tertiary),
                const SizedBox(width: 8),
                Expanded(child: Text(_t(SurfacesText.previewsHeader), style: theme.textTheme.titleMedium)),
                Text('${_previews.length}', style: theme.textTheme.titleMedium),
              ],
            ),
          ),
        ),
        for (final p in _previews) _previewTile(p),
        if (_rows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(_t(SurfacesText.yourApps), style: theme.textTheme.titleSmall),
          ),
      ],
      for (final row in _rows) _appTile(row),
      _createHint(),
    ];
  }

  /// Apps are made by chatting with Hermes; the header's Open chat is the one way there.
  Widget _createHint() => AppsHint(key: const ValueKey('apps-create-hint'), text: _t(SurfacesText.createAppHint));

  /// Explanation cards for the states without a list. Each offers at most one way forward.
  List<Widget> _stateChildren(_Body body) {
    final configure = widget.onConfigure != null;
    final notice = widget.hostNotice;
    return switch (body) {
      _Body.list || _Body.connecting => const [],
      _Body.setup => [
        AppsInfoCard(
          icon: Icons.apps_outlined,
          title: _t(SurfacesText.setupTitle),
          message: _t(SurfacesText.setupMessage),
          steps: [_t(SurfacesText.setupStep1), _t(SurfacesText.setupStep2), _t(SurfacesText.setupStep3)],
          actions: [
            if (widget.onPasteCode != null) _pasteCodeButton(),
            _configureButton(primary: widget.onPasteCode == null),
          ],
          footnote: _t(SurfacesText.setupChatNote),
        ),
      ],
      _Body.standalone => [
        AppsInfoCard(
          icon: Icons.apps_outlined,
          title: _t(SurfacesText.setupTitle),
          message: _t(SurfacesText.standaloneMessage),
        ),
      ],
      _Body.notice => [
        AppsInfoCard(
          icon: Icons.info_outline,
          title: _t(SurfacesText.noticeTitle),
          message: notice == null ? null : _t(notice),
          tone: AppsTone.warn,
          footnote: _t(SurfacesText.noticeFootnote),
        ),
      ],
      _Body.address => [
        AppsInfoCard(
          icon: Icons.link_off,
          title: _t(SurfacesText.chipUnavailable),
          message: _t(SurfacesText.addressMessage),
          tone: AppsTone.error,
          actions: [if (configure) _configureButton(primary: true)],
        ),
      ],
      _Body.unauthorized => [
        AppsInfoCard(
          icon: Icons.lock_outline,
          title: _t(SurfacesText.unauthorizedTitle),
          message: _t(SurfacesText.unauthorizedMessage),
          tone: AppsTone.error,
          actions: [
            if (widget.onPasteCode != null) _pasteCodeButton(),
            if (configure) _configureButton(primary: widget.onPasteCode == null),
            _retryButton(),
          ],
        ),
      ],
      _Body.failed => [
        AppsInfoCard(
          icon: Icons.error_outline,
          title: _t(SurfacesText.failedTitle),
          message: _t(SurfacesText.failedMessage),
          tone: AppsTone.error,
          actions: [_retryButton()],
        ),
      ],
      _Body.offlineEmpty => [
        AppsInfoCard(
          icon: Icons.cloud_off_outlined,
          title: _t(SurfacesText.noAppsTitle),
          message: _t(SurfacesText.noAppsOfflineMessage),
          tone: AppsTone.warn,
          actions: [_retryButton()],
        ),
      ],
      _Body.empty => [
        AppsInfoCard(
          icon: Icons.apps_outlined,
          title: _t(SurfacesText.noAppsTitle),
          message: _t(SurfacesText.noAppsMessage),
        ),
        _createHint(),
      ],
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = _session;
    final body = _bodyKind();
    final configure = widget.onConfigure != null;
    // The settings action sits in the header only while no card below already offers it.
    final cardConfigures = configure && (body == _Body.setup || body == _Body.address || body == _Body.unauthorized);
    final showSettings = configure && !cardConfigures;
    final showRefresh = session != null;
    final canRefresh = !_busy && session?.host != null;
    final (statusIcon, statusLabel, statusTone) = _chip();
    final scrollable = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 16),
      children: body == _Body.list ? _listChildren() : _stateChildren(body),
    );
    final column = Column(
      children: [
        if (widget.embedded) _header(showRefresh: showRefresh, canRefresh: canRefresh, showSettings: showSettings),
        SizedBox(height: 4, child: _busy ? const LinearProgressIndicator() : null),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppsStatusChip(
              key: const ValueKey('apps-status-chip'),
              icon: statusIcon,
              label: statusLabel,
              tone: statusTone,
            ),
          ),
        ),
        if (_reviewStatus != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(_t(_reviewStatus!), style: theme.textTheme.bodySmall)),
              ],
            ),
          ),
        Expanded(
          child: session?.host != null
              ? RefreshIndicator(
                  onRefresh: _pullRefresh,
                  semanticsLabel: _t(SurfacesText.refreshList),
                  child: scrollable,
                )
              : scrollable,
        ),
      ],
    );
    if (widget.embedded) return column;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? _t(SurfacesText.appsTitle)),
        actions: [
          if (showRefresh) _refreshAction(labelled: false, enabled: canRefresh),
          TextButton.icon(
            onPressed: _chat,
            icon: const Icon(Icons.chat_outlined),
            label: Text(_t(SurfacesText.openChat)),
          ),
          if (showSettings) _settingsAction(labelled: false),
          ...widget.appBarActions,
        ],
      ),
      body: column,
    );
  }
}

class _Row {
  _Row(this.appId, this.title, this.revision, this.installed);
  final String appId;
  final String title;
  final int revision;
  final InstalledApp? installed;
}

/// This listener lives ON the native route, not only on the (possibly offstage) catalogue.
/// Once invalidated it never revives, even if a user switches back to the original binding.
class _BoundSurfacePage extends StatefulWidget {
  const _BoundSurfacePage({required this.session, required this.request, this.builder});
  final _Session session;
  final SurfacePageRequest request;
  final SurfacePageBuilder? builder;
  @override
  State<_BoundSurfacePage> createState() => _BoundSurfacePageState();
}

class _BoundSurfacePageState extends State<_BoundSurfacePage> {
  bool _blocked = false;
  @override
  void initState() {
    super.initState();
    _blocked = !widget.session.current;
    widget.session.active.addListener(_check);
    widget.session.bridge.activeConnection.addListener(_check);
  }

  void _check() {
    if (!_blocked && !widget.session.current) setState(() => _blocked = true);
  }

  @override
  void dispose() {
    widget.session.active.removeListener(_check);
    widget.session.bridge.activeConnection.removeListener(_check);
    super.dispose();
  }

  Future<void> _currentChat() async {
    final bridge = widget.session.bridge;
    final binding = bridge.activeConnection.value;
    if (mounted && sameConnection(binding, bridge.activeConnection.value)) await bridge.openChat();
  }

  @override
  Widget build(BuildContext context) {
    final t = SurfacesStrings.of(context);
    if (_blocked || !widget.session.current) {
      return Scaffold(
        appBar: AppBar(title: Text(t(SurfacesText.closedTitle))),
        body: Center(child: Text(t(SurfacesText.closedMessage))),
        bottomNavigationBar: SafeArea(
          child: TextButton(onPressed: _currentChat, child: Text(t(SurfacesText.openChat))),
        ),
      );
    }
    final request = widget.request;
    return Column(
      // The bar below must span the width: shrunk to its button, the page behind showed through at the sides.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child:
              widget.builder?.call(context, request) ??
              SurfaceView(
                host: request.host,
                config: request.connection.config,
                app: request.app,
                title: request.title,
                strictNetworkBlock: request.connection.strictNetworkBlock,
                sealNetwork: request.connection.sealNetwork,
                preview: request.preview,
                onDiag: request.onDiag,
                fileActions: request.fileActions,
                sendToHermes: request.sendToHermes,
              ),
        ),
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            top: false,
            child: TextButton.icon(
              onPressed: request.openChat,
              icon: const Icon(Icons.chat_outlined),
              label: Text(t(SurfacesText.openChat)),
            ),
          ),
        ),
      ],
    );
  }
}
