import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import 'api.dart';
import 'approval.dart' show ApprovalFailure;
import 'bridge.dart';
import 'bundle_store.dart';
import 'file_bridge.dart';
import 'hardening.dart';
import 'host.dart';
import 'mutation_bridge.dart';
import 'network_sink.dart';
import 'origin.dart';
import 'strings.dart';

/// Name of the object injected into the page. Only frames of the app's own origin get it.
const String hostObjectName = 'hermesHost';

/// One diagnostic line shown in the host's debug sheet (never sent to the page).
class DiagEntry {
  DiagEntry(this.kind, this.text) : at = DateTime.now();
  final String kind; // blocked | bridge | console | nav | system
  final String text;
  final DateTime at;
}

/// What the user can decide while looking at a build under review (ADR-007 §5).
///
/// [approve] receives the installed app that is on screen, so the signature covers exactly the
/// bundle the user saw. It returns null on success or a message to show.
class PreviewActions {
  PreviewActions({required this.approve, required this.reject});
  final Future<String?> Function(InstalledApp shown) approve;
  final Future<void> Function(InstalledApp shown) reject;
}

/// A mini-app screen: native frame around a locked-down WebView (ADR-001 §4, ADR-006).
class SurfaceView extends StatefulWidget {
  const SurfaceView({
    super.key,
    required this.host,
    required this.config,
    required this.app,
    required this.title,
    this.strictNetworkBlock = true,
    this.sealNetwork = true,
    this.onDiag,
    this.preview,
    this.fileActions,
    this.sendToHermes,
  });

  final SurfacesHost host;
  final ServerConfig config;
  final InstalledApp app;
  final String title;

  /// The application's file picker and "open / save / share" sheet. Without it a page that asks to move a file is
  /// told this version cannot, and nothing happens.
  final HostFileActions? fileActions;

  /// Opens a chat with Hermes and sends the given text as the user's message (after the user confirmed it here).
  final SendToHermes? sendToHermes;

  /// Non-null when this is a build awaiting the user's approval rather than a published app. The
  /// host must then be built on a [PreviewApi] and a [ServerConfig.forPreview] scope.
  final PreviewActions? preview;

  /// Route all WebView traffic into a loopback sink (ProxyController). On by default and
  /// fail-closed: if it cannot be installed the page is not started. Turning it off exists only
  /// to measure what the other layers stop on their own.
  final bool sealNetwork;

  /// Receives every diagnostic line as it is produced (the example writes them to a file).
  final void Function(DiagEntry entry)? onDiag;

  /// WebView's own switch that refuses all network loads. Interception and CSP do not depend on
  /// it; it exists as an extra layer and can be turned off to diagnose a blank page.
  final bool strictNetworkBlock;

  @override
  State<SurfaceView> createState() => _SurfaceViewState();
}

/// Why the page was not started: a localized reason (by key) with an optional technical detail.
class _SealFailure {
  const _SealFailure(this.key, this.detail, {this.fallback});
  final SurfacesText? key;
  final String? detail;
  final String? fallback;

  String describe(SurfacesStrings t) {
    final k = key;
    if (k == null) return fallback ?? '';
    return t(k, {'detail': detail ?? ''});
  }
}

// A main-document load may be reported by interception before onLoadStart, or vice versa.
// Pair the two without reusing a successful delivery from an earlier navigation.
class _DocumentLoad {
  _DocumentLoad(this.path);
  final String path;
  bool started = false;
  bool intercepted = false;
  bool delivered = false;
}

class _SurfaceViewState extends State<SurfaceView> with WidgetsBindingObserver {
  late InstalledApp _app = widget.app;
  late final AppOrigin _origin = AppOrigin.forApp(widget.config.scope, _app.appId);
  late BridgeGate _gate = BridgeGate(expectedOrigin: _origin.origin);
  InAppWebViewController? _controller;
  Timer? _poll;
  String _timezone = 'UTC';
  String? _epoch;
  int _cursor = 0;
  bool _loading = true;
  bool _bridgeMissing = false;
  _SealFailure? _sealFailure;
  StreamSubscription<String>? _sinkSub;
  bool _rendererGone = false;
  DateTime? _staleSince;
  final List<DiagEntry> _diag = [];
  StreamSubscription<Connectivity>? _connSub;
  bool _reviewGone = false;
  bool _deciding = false;
  bool _sendingDecision = false;
  int _pageGeneration = 0;
  _DocumentLoad? _document;
  _DocumentLoad? _readyDocument;
  late BundlePin _appPin;
  late final FileBridge _files = FileBridge(
    actions: widget.fileActions,
    sendToHermes: widget.sendToHermes,
    preview: widget.preview != null,
    timezone: () => _timezone,
  );
  late final MutationBridge _mutations = MutationBridge(preview: widget.preview != null, timezone: () => _timezone);
  Future<void>? _updating;
  bool _backPending = false;
  String? _decisionError;

  /// The viewer's language, kept current by [didChangeDependencies] so async completions (which have
  /// no safe BuildContext) can still word what they report.
  SurfacesStrings _strings = SurfacesStrings.forLanguage(null);

  bool _currentPage(int generation) => mounted && !_reviewGone && generation == _pageGeneration;

  bool _currentDocument(int generation, _DocumentLoad? document) =>
      _currentPage(generation) && identical(document, _document);

  bool get _previewReady => _app.preview != null && _document != null &&
      identical(_readyDocument, _document) && _document!.delivered && _updating == null && !_loading &&
      !_bridgeMissing && _sealFailure == null && !_rendererGone;

  bool _sameTarget(InstalledApp a, InstalledApp b) =>
      a.appId == b.appId && a.bundleId == b.bundleId && a.revision == b.revision && a.preview == b.preview;

  void _newPage() {
    _pageGeneration++;
    _document = null;
    _readyDocument = null;
    _loading = true;
    _rendererGone = false;
    _sealFailure = null;
    _controller = null;
    _gate = BridgeGate(expectedOrigin: _origin.origin);
  }

  _DocumentLoad _beginDocument(String path) {
    final document = _DocumentLoad(path);
    setState(() {
      _document = document;
      _readyDocument = null;
      _loading = true;
      _gate = BridgeGate(expectedOrigin: _origin.origin);
    });
    return document;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _strings = SurfacesStrings.of(context);
  }

  @override
  void initState() {
    super.initState();
    _appPin = widget.host.bundles.pin(_app);
    WidgetsBinding.instance.addObserver(this);
    FlutterTimezone.getLocalTimezone().then((t) => _timezone = t.identifier).catchError((_) => 'UTC');
    _connSub = widget.host.connectivity.changes.listen((c) {
      if (!mounted) return;
      setState(() {});
      if (c == Connectivity.online) _pushDataChanged();
    });
    var ticks = 0;
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollEvents());
      // Events can be missed (cursor reset, server restart). A build under review is therefore also
      // compared with the server every few seconds, so the owner never has to reopen it.
      if (widget.preview != null && ++ticks % 3 == 0 && !_deciding && !_sendingDecision) {
        unawaited(_checkUpdate(quiet: true));
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _connSub?.cancel();
    _sinkSub?.cancel();
    _appPin.release();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pollEvents();
      unawaited(_checkUpdate(quiet: true));
      _pushDataChanged();
    }
  }

  void _log(String kind, String text) {
    if (!mounted) return;
    final entry = DiagEntry(kind, text);
    _diag.add(entry);
    if (_diag.length > 300) _diag.removeAt(0);
    widget.onDiag?.call(entry);
  }

  /// Installs the network seal and starts the page. Anything but success leaves the page unstarted.
  Future<void> _startPage(InAppWebViewController c, InstalledApp app, int generation) async {
    if (!_currentPage(generation)) return;
    if (widget.sealNetwork) {
      // The WebRTC removal script is injected by the WebView before page scripts; without
      // DOCUMENT_START_SCRIPT it would run too late, so the page is not started at all.
      if (!await WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
        const failure = _SealFailure(SurfacesText.sealNoDocumentStartScript, null);
        _log('system', 'NETWORK NOT SEALED: DOCUMENT_START_SCRIPT is not supported');
        if (_currentPage(generation)) setState(() => _sealFailure = failure);
        return;
      }
      try {
        final sink = await NetworkSeal.install();
        if (!_currentPage(generation)) return;
        _sinkSub ??= sink.attempts.listen((line) => _log('network', 'REFUSED $line'));
        _log('system', 'network sealed: all WebView traffic goes to a loopback sink (port ${sink.port})');
      } on NetworkSealException catch (e) {
        _log('system', 'NETWORK NOT SEALED: ${e.message}');
        if (_currentPage(generation)) {
          setState(() => _sealFailure = _SealFailure(e.key, e.detail, fallback: e.message));
        }
        return;
      }
    } else {
      _log('system', 'WARNING: network seal disabled (diagnostic run)');
    }
    if (!_currentPage(generation)) return;
    await c.loadUrl(urlRequest: URLRequest(url: WebUri('${_origin.origin}/${app.entrypoint}')));
  }

  // -- server events ---------------------------------------------------------

  var _polling = false;

  Future<void> _pollEvents() async {
    if (_polling || _reviewGone || _sendingDecision || !mounted) return;
    _polling = true;
    try {
      final res = await widget.host.api.events(since: _cursor, epoch: _epoch ?? '');
      if (!mounted || _reviewGone || _sendingDecision) return;
      widget.host.connectivity.value = Connectivity.online;
      final reset = res['reset'] == true;
      _epoch = res['epoch'] as String;
      _cursor = res['seq'] as int;
      if (reset) {
        await _checkUpdate();
        _pushDataChanged();
        return;
      }
      var data = false, bundle = false, files = false;
      for (final e in (res['events'] as List).cast<Map<String, dynamic>>()) {
        if (e['appId'] != _app.appId) continue;
        final type = e['type'];
        if (type == 'data.changed') data = true;
        if (type == 'files.changed') {
          files = true;
          final payload = e['payload'];
          if (payload is Map && payload['change'] == 'deleted' && payload['fileId'] is String) {
            _files.forgetFile(_app.appId, payload['fileId'] as String);
          }
        }
        if (type == 'bundle.changed' || type == 'app.changed') bundle = true;
        if (type == 'review.changed' && widget.preview != null) {
          bundle = true; // reconcile the current review, not intermediate journal states
        }
      }
      if (bundle) await _checkUpdate();
      if (data) _pushDataChanged();
      if (files) _pushFilesChanged();
    } on OfflineException {
      widget.host.connectivity.value = Connectivity.offline;
    } on ApiException catch (e) {
      if (e.isUnauthorized) widget.host.connectivity.value = Connectivity.unauthorized;
    } finally {
      _polling = false;
    }
  }

  void _finishReview() {
    if (widget.preview == null || !mounted || _reviewGone) return;
    setState(() {
      _reviewGone = true;
      _decisionError = null;
      _pageGeneration++;
      _document = null;
      _readyDocument = null;
    });
    _controller = null;
  }

  /// A background comparison with the server (timer, return to the app) that never disturbs what is on
  /// screen: unlike a visible refresh it does not mark the page as updating, so the Publish button does not
  /// grey out and a tap on it is not lost. If it does find a new build, the page is replaced and the usual
  /// guards (same target, same document, ready) ask for a fresh decision.
  bool _quietChecking = false;

  Future<void> _checkUpdate({bool quiet = false}) {
    if (_reviewGone || _sendingDecision || !mounted) return Future.value();
    final existing = _updating;
    if (existing != null) return existing;
    if (quiet) {
      if (_quietChecking) return Future.value();
      _quietChecking = true;
      return _applyUpdate().whenComplete(() => _quietChecking = false);
    }
    late final Future<void> pending;
    pending = _applyUpdate().whenComplete(() {
      if (identical(_updating, pending)) {
        if (mounted) {
          setState(() => _updating = null);
        } else {
          _updating = null;
        }
      }
    });
    setState(() {
      _updating = pending;
    });
    return pending;
  }

  Future<void> _applyUpdate() async {
    InstalledApp? candidate;
    try {
      candidate = await widget.host.checkForUpdate(_app.appId, displayed: _app);
    } on HostError catch (e) {
      if (e.code != 'preview_gone') rethrow;
      _finishReview();
      return;
    }
    final updated = candidate;
    if (updated == null || !mounted || _reviewGone) return;
    // Two checks can finish with the same new build (a quiet one and a visible one are serialized by the
    // host, but both were asked before either installed): swap the page once.
    if (_sameTarget(updated, _app) && updated.contractHash == _app.contractHash && updated.epoch == _app.epoch) {
      return;
    }
    final pin = widget.host.bundles.pin(updated);
    final previous = _appPin;
    _log('system', 'installed revision ${updated.revision} (${updated.bundleId.substring(7, 15)})');
    setState(() {
      _app = updated;
      _appPin = pin;
      _newPage();
    });
    previous.release();
    final t = SurfacesStrings.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t(SurfacesText.appUpdatedTo, {'revision': updated.revision}))),
    );
  }

  void _pushDataChanged() {
    if (_reviewGone || _sendingDecision) return;
    _controller?.evaluateJavascript(source: "window.dispatchEvent(new Event('hermes:data-changed'))");
  }

  /// The app's stored files changed (a picture the author imported, a file deleted on another device): a page
  /// that lists them asks again.
  void _pushFilesChanged() {
    if (_reviewGone || _sendingDecision) return;
    _controller?.evaluateJavascript(source: "window.dispatchEvent(new Event('hermes:files-changed'))");
  }

  // -- request interception ----------------------------------------------------

  WebResourceResponse _local(int status, String reason, String mime, Uint8List body) => WebResourceResponse(
        contentType: mime,
        contentEncoding: isTextMime(mime) ? 'utf-8' : null,
        statusCode: status,
        reasonPhrase: reason,
        headers: securityHeaders,
        data: body,
      );

  /// Never returns null and never throws: a null/exception would give the request back to the
  /// WebView to load itself. Every failure path ends in a local refusal instead.
  Future<WebResourceResponse?> _intercept(
      InAppWebViewController c, WebResourceRequest request, InstalledApp app, int generation) async {
    try {
      final url = request.url.toString();
      final decision = classifyRequest(_origin, url, request.method ?? 'GET');
      _DocumentLoad? document;
      if (request.isForMainFrame == true) {
        final path = decision.verdict == RequestVerdict.serve
            ? (decision.path.isEmpty ? app.entrypoint : decision.path) : url;
        document = _document;
        if (document == null || document.intercepted || document.path != path) {
          document = _beginDocument(path);
        }
        document.intercepted = true;
      }
      switch (decision.verdict) {
        case RequestVerdict.foreign:
        case RequestVerdict.malformed:
          _log('blocked', '${request.method} $url');
          return _local(403, 'Blocked', 'text/plain', Uint8List(0));
        case RequestVerdict.badMethod:
          _log('blocked', '${request.method} $url');
          return _local(405, 'Method Not Allowed', 'text/plain', Uint8List(0));
        case RequestVerdict.serve:
          final path = decision.path.isEmpty ? app.entrypoint : decision.path;
          if (path.startsWith(filesPathPrefix)) {
            // A stored picture of THIS app, asked for by an id the server issued; never a path or an address.
            final picture = await _files.picture(widget.host, app, path.substring(filesPathPrefix.length));
            if (picture == null) {
              _log('blocked', 'no picture: $path');
              return _local(404, 'Not Found', 'text/plain', Uint8List(0));
            }
            if (!_currentPage(generation)) return _local(403, 'Blocked', 'text/plain', Uint8List(0));
            return _local(200, 'OK', picture.mime, picture.bytes);
          }
          final bytes = await widget.host.bundles.read(app, path);
          if (bytes == null) {
            _log('blocked', 'not in bundle: $path');
            return _local(404, 'Not Found', 'text/plain', Uint8List(0));
          }
          if (!_currentPage(generation)) return _local(403, 'Blocked', 'text/plain', Uint8List(0));
          if (document != null && _currentDocument(generation, document) && mimeFor(path) == 'text/html') {
            document.delivered = true;
          }
          return _local(200, 'OK', mimeFor(path), bytes);
      }
    } catch (e) {
      _log('blocked', 'interceptor error, request refused: $e');
      return _local(403, 'Blocked', 'text/plain', Uint8List(0));
    }
  }

  // -- bridge ---------------------------------------------------------------

  void _onMessage(WebMessage? message, WebUri? sourceOrigin, bool isMainFrame, PlatformJavaScriptReplyProxy reply) {
    unawaited(_process(message, sourceOrigin, isMainFrame, reply,
        _gate, _app, _pageGeneration, _document));
  }

  Future<void> _process(WebMessage? message, WebUri? sourceOrigin, bool isMainFrame,
      PlatformJavaScriptReplyProxy reply, BridgeGate gate, InstalledApp app,
      int generation, _DocumentLoad? document) async {
    final origin = sourceOrigin?.toString().replaceFirst(RegExp(r'/$'), '');
    final raw = message?.data is String ? message!.data as String : null;
    final BridgeRequest req;
    try {
      req = gate.accept(raw, sourceOrigin: origin, isMainFrame: isMainFrame);
    } on BridgeRejected catch (e) {
      _log('bridge', 'REJECTED ${e.code}: ${e.detail}');
      reply.postMessage(WebMessage(data: BridgeGate.error(e.id, e.code, 'rejected')));
      return;
    }
    try {
      final value = await _handle(req, app, generation, document);
      if (_currentDocument(generation, document)) {
        reply.postMessage(WebMessage(data: BridgeGate.ok(req.id, value)));
      }
    } on HostError catch (e) {
      if (!_currentDocument(generation, document)) return;
      _log('bridge', '${req.op} -> ${e.code}');
      // The page gets the message in the viewer's language; the stable code is what it branches on.
      final text = _strings.describe(e.key, e.message);
      reply.postMessage(WebMessage(data: BridgeGate.error(req.id, e.code, text)));
      if (e.code == 'stale_revision') unawaited(_checkUpdate());
      if (e.code == 'preview_gone') _finishReview();
    } catch (e) {
      if (!_currentDocument(generation, document)) return;
      _log('bridge', '${req.op} failed: $e');
      // A release build keeps no diagnostics list: say what kind of failure it was (the type only, a message can carry
      // an address) where `adb logcat` can see it.
      debugPrint('surfaces bridge: ${req.op} failed with ${e.runtimeType}');
      reply.postMessage(WebMessage(data: BridgeGate.error(req.id, 'internal', 'host error')));
    } finally {
      gate.release();
    }
  }

  Future<Object?> _handle(BridgeRequest req, InstalledApp app, int generation, _DocumentLoad? document) async {
    switch (req.op) {
      case 'hello':
        // appId and revision come from the captured host state, never from the page.
        return {'bridgeVersion': 1, 'sdkMajor': 1, 'appId': app.appId, 'revision': app.revision};
      case 'hostState':
        return {
          'locale': WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag(),
          'theme': MediaQuery.platformBrightnessOf(context) == Brightness.dark ? 'dark' : 'light',
          'timezone': _timezone,
          'online': widget.host.connectivity.value == Connectivity.online,
          'preview': widget.preview != null,
        };
      case 'query':
        final out = await widget.host.query(app, req.calls, timezone: _timezone);
        if (_currentDocument(generation, document)) {
          setState(() => _staleSince = out.fromCache ? out.fetchedAt : null);
        }
        return out.reply;
      case 'pickFile':
      case 'listFiles':
      case 'deleteFile':
      case 'saveFile':
      case 'askHermes':
        // Native steps (a picker, a sheet, a confirmation) need a live screen showing THIS page.
        if (!_currentDocument(generation, document) || !mounted) throw HostError('closed', 'The page is closed');
        return _files.handle(req, host: widget.host, app: app, title: widget.title, context: context);
      case 'mutate':
        // May ask the user first, so it too needs a live screen showing THIS page.
        if (!_currentDocument(generation, document) || !mounted) throw HostError('closed', 'The page is closed');
        return _mutations.handle(req, host: widget.host, app: app, title: widget.title, context: context);
    }
    throw HostError('unknown_op', req.op);
  }

  // -- UI ---------------------------------------------------------------------

  Future<void> _reload() async {
    if (_sendingDecision || _reviewGone) return;
    setState(_newPage);
  }

  Future<void> _approve() async {
    final actions = widget.preview;
    if (actions == null || _deciding || _reviewGone || !_previewReady) return;
    final shown = _app;
    final generation = _pageGeneration;
    final document = _document;
    final route = ModalRoute.of(context);
    setState(() {
      _deciding = true;
      _decisionError = null;
    });
    final t = SurfacesStrings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t(SurfacesText.publishDialogTitle)),
        content: Text(t(SurfacesText.publishDialogBody, {'title': widget.title})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t(SurfacesText.cancel))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t(SurfacesText.publish))),
        ],
      ),
    );
    if (!mounted) return;
    if (ok != true || _reviewGone || route?.isCurrent != true) {
      setState(() => _deciding = false);
      return;
    }
    if (!_currentDocument(generation, document) || !_sameTarget(shown, _app) || !_previewReady) {
      setState(() {
        _deciding = false;
        _decisionError = t(SurfacesText.buildChanged);
      });
      return;
    }
    String? error;
    _sendingDecision = true;
    try {
      error = await actions.approve(shown);
    } catch (e) {
      error = t(SurfacesText.publishFailed, {'detail': e});
    } finally {
      _sendingDecision = false;
    }
    if (!mounted) return;
    if (error == null) {
      if (route?.isCurrent == true) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _deciding = false);
        _finishReview();
      }
    } else {
      setState(() {
        _deciding = false;
        _decisionError = error;
      });
      unawaited(_checkUpdate());
    }
  }

  Future<void> _reject() async {
    final actions = widget.preview;
    if (actions == null || _deciding || _reviewGone) return;
    final shown = _app;
    final route = ModalRoute.of(context);
    setState(() => _deciding = true);
    _sendingDecision = true;
    final t = SurfacesStrings.of(context);
    String? error;
    var gone = false;
    try {
      await actions.reject(shown);
    } on ApiException catch (e) {
      gone = e.status == 404;
      if (!gone) error = t(SurfacesText.rejectFailed, {'detail': e.message});
    } on OfflineException {
      error = t(SurfacesText.rejectOffline);
    } on ApprovalFailure catch (e) {
      error = t(SurfacesText.rejectFailed, {'detail': t.describe(e.key, e.message)});
    } catch (e) {
      error = t(SurfacesText.rejectFailed, {'detail': e});
    } finally {
      _sendingDecision = false;
    }
    if (!mounted) return;
    if (gone) {
      setState(() => _deciding = false);
      _finishReview();
      return;
    }
    if (error != null) {
      setState(() {
        _deciding = false;
        _decisionError = error;
      });
      unawaited(_checkUpdate());
      return;
    }
    if (route?.isCurrent == true) {
      Navigator.of(context).pop(false);
    } else {
      setState(() => _deciding = false);
      _finishReview();
    }
  }

  Future<void> _back() async {
    if (_deciding || _backPending) return;
    final controller = _controller;
    final generation = _pageGeneration;
    final document = _document;
    final route = ModalRoute.of(context);
    _backPending = true;
    try {
      final canGoBack = await controller?.canGoBack() ?? false;
      if (!mounted || _deciding || generation != _pageGeneration || !identical(document, _document) ||
          !identical(controller, _controller) || route?.isCurrent != true) {
        return;
      }
      if (canGoBack) {
        await controller!.goBack();
      } else {
        Navigator.of(context).pop();
      }
    } finally {
      _backPending = false;
    }
  }

  Future<void> _showDiagnostics() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            Text(SurfacesStrings.of(ctx)(SurfacesText.diagnostics), style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 8),
            SelectableText('origin: ${_origin.origin}\n'
                'bundle: ${_app.bundleId}\nrevision: ${_app.revision}\n'
                'contract: ${_app.contractHash}\nepoch: ${_app.epoch}\n'
                'files: ${_app.files.length}\ntimezone: $_timezone'),
            const Divider(),
            for (final e in _diag.reversed)
              Text('${e.at.toIso8601String().substring(11, 19)} [${e.kind}] ${e.text}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = SurfacesStrings.of(context);
    final conn = widget.host.connectivity.value;
    final offline = conn == Connectivity.offline;
    final generation = _pageGeneration;
    final pageApp = _app;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _back();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title, style: const TextStyle(fontSize: 16)),
            Text(
                widget.preview != null
                    ? t(_reviewGone ? SurfacesText.previewFinished : SurfacesText.previewNotPublished)
                    : t(SurfacesText.createdByHermes, {'revision': _app.revision}),
                style: Theme.of(context).textTheme.labelSmall),
          ]),
          actions: [
            Icon(offline ? Icons.cloud_off : (conn == Connectivity.unauthorized ? Icons.lock_outline : Icons.cloud_done_outlined),
                semanticLabel: t(offline
                    ? SurfacesText.chipOffline
                    : (conn == Connectivity.unauthorized ? SurfacesText.accessDenied : SurfacesText.chipOnline)),
                color: conn == Connectivity.unauthorized
                    ? Theme.of(context).colorScheme.error
                    : (offline ? Theme.of(context).colorScheme.tertiary : Theme.of(context).colorScheme.primary)),
            IconButton(
              tooltip: t(SurfacesText.refresh),
              icon: const Icon(Icons.refresh),
              onPressed: _deciding ? null : () async {
                await _checkUpdate();
                _pushDataChanged();
              },
            ),
            // The debug sheet is for developers: a release build shows an app page without a bug button.
            if (kDebugMode)
              IconButton(tooltip: t(SurfacesText.diagnostics), icon: const Icon(Icons.bug_report_outlined),
                  onPressed: _deciding ? null : _showDiagnostics),
          ],
        ),
        bottomNavigationBar: widget.preview == null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_reviewGone)
                      FilledButton(
                        onPressed: _deciding ? null : () => Navigator.of(context).pop(),
                        child: Text(t(SurfacesText.backToList)),
                      )
                    else ...[
                    if (_decisionError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(_decisionError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _deciding ? null : _reject,
                          child: Text(t(SurfacesText.reject)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _deciding || _reviewGone || offline || conn == Connectivity.unauthorized || !_previewReady
                              ? null : _approve,
                          child: _deciding
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : Text(t(SurfacesText.publish)),
                        ),
                      ),
                    ]),
                    ],
                  ]),
                ),
              ),
        body: Column(children: [
          if (widget.preview != null)
            MaterialBanner(
              content: Text(_reviewGone
                  ? t(SurfacesText.previewGoneBanner)
                  : t(SurfacesText.previewBanner)),
              actions: const [SizedBox.shrink()],
              backgroundColor: (_reviewGone ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary)
                  .withValues(alpha: 0.15),
            ),
          if (offline || _staleSince != null)
            MaterialBanner(
              content: Text(_staleSince != null
                  ? t(SurfacesText.offlineSince, {'time': _staleSince!.toLocal().toString().substring(11, 19)})
                  : t(SurfacesText.noConnection)),
              actions: const [SizedBox.shrink()],
              backgroundColor: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.15),
            ),
          if (conn == Connectivity.unauthorized)
            MaterialBanner(content: Text(t(SurfacesText.unauthorizedBanner)), actions: const [SizedBox.shrink()]),
          Expanded(
            child: _reviewGone
                ? Center(child: Text(t(SurfacesText.previewFinished)))
                : Stack(children: [
              if (_bridgeMissing)
                Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(t(SurfacesText.bridgeMissing))))
              else if (_sealFailure != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(t(SurfacesText.appNotStarted, {'reason': _sealFailure!.describe(t)})),
                  ),
                )
              else
                InAppWebView(
                  key: ValueKey(generation),
                  initialSettings: _settings,
                  initialUserScripts: widget.sealNetwork
                      ? UnmodifiableListView<UserScript>([
                          UserScript(
                            source: documentStartHardening,
                            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                            forMainFrameOnly: false,
                          ),
                        ])
                      : null,
                  onWebViewCreated: (c) async {
                    if (!_currentPage(generation)) return;
                    _controller = c;
                    if (!await WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
                      if (_currentPage(generation)) setState(() => _bridgeMissing = true);
                      return;
                    }
                    if (!_currentPage(generation)) return;
                    await c.addWebMessageListener(WebMessageListener(
                      jsObjectName: hostObjectName,
                      allowedOriginRules: {_origin.origin},
                      onPostMessage: (message, origin, mainFrame, reply) {
                        if (_currentPage(generation)) _onMessage(message, origin, mainFrame, reply);
                      },
                    ));
                    await _startPage(c, pageApp, generation);
                  },
                  shouldInterceptRequest: (c, request) => _currentPage(generation)
                      ? _intercept(c, request, pageApp, generation)
                      : Future.value(_local(403, 'Blocked', 'text/plain', Uint8List(0))),
                  shouldOverrideUrlLoading: (c, action) async {
                    if (!_currentPage(generation) || (_sendingDecision && action.isForMainFrame)) {
                      return NavigationActionPolicy.CANCEL;
                    }
                    // Only a well-formed GET inside our own origin may navigate; everything else,
                    // including URLs that fail to parse, is cancelled.
                    final d = classifyRequest(_origin, action.request.url.toString(), action.request.method ?? 'GET');
                    if (d.verdict == RequestVerdict.serve) return NavigationActionPolicy.ALLOW;
                    _log('nav', 'cancelled ${action.request.url}');
                    return NavigationActionPolicy.CANCEL;
                  },
                  onCreateWindow: (c, action) async {
                    _log('nav', 'new window refused ${action.request.url}');
                    return false;
                  },
                  onPermissionRequest: (c, req) async {
                    _log('blocked', 'permission ${req.resources}');
                    return PermissionResponse(resources: req.resources, action: PermissionResponseAction.DENY);
                  },
                  onGeolocationPermissionsShowPrompt: (c, origin) async {
                    _log('blocked', 'geolocation $origin');
                    return GeolocationPermissionShowPromptResponse(origin: origin, allow: false, retain: false);
                  },
                  onDownloadStartRequest: (c, req) async => _log('blocked', 'download ${req.url}'),
                  onConsoleMessage: (c, m) => _log('console', '${m.messageLevel}: ${m.message}'),
                  onLoadStart: (c, url) {
                    if (!_currentPage(generation) || url == null) return;
                    final decision = classifyRequest(_origin, url.toString(), 'GET');
                    final path = decision.verdict == RequestVerdict.serve
                        ? (decision.path.isEmpty ? pageApp.entrypoint : decision.path) : url.toString();
                    var document = _document;
                    if (document == null || document.started || document.path != path) {
                      document = _beginDocument(path);
                    }
                    document.started = true;
                  },
                  onLoadStop: (c, url) {
                    if (!_currentPage(generation) || url == null) return;
                    final decision = classifyRequest(_origin, url.toString(), 'GET');
                    final path = decision.path.isEmpty ? pageApp.entrypoint : decision.path;
                    final document = _document;
                    if (decision.verdict != RequestVerdict.serve || document == null ||
                        document.path != path || !document.started) {
                      return;
                    }
                    setState(() {
                      _loading = false;
                      _readyDocument = document.delivered ? document : null;
                    });
                  },
                  onRenderProcessGone: (c, detail) {
                    _log('system', 'renderer gone (crashed: ${detail.didCrash})');
                    if (_currentPage(generation)) setState(() => _rendererGone = true);
                  },
                  onRenderProcessUnresponsive: (c, url) async {
                    _log('system', 'renderer unresponsive: terminating');
                    return WebViewRenderProcessAction.TERMINATE;
                  },
                ),
              if (_loading && !_bridgeMissing && _sealFailure == null) const LinearProgressIndicator(),
              if (_rendererGone)
                Container(
                  color: Theme.of(context).colorScheme.surface,
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(t(SurfacesText.appStopped)),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _reload, child: Text(t(SurfacesText.restart))),
                    ]),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  InAppWebViewSettings get _settings => InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldInterceptRequest: true,
        useShouldOverrideUrlLoading: true,
        blockNetworkLoads: widget.strictNetworkBlock,
        allowFileAccess: false,
        allowContentAccess: false,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        domStorageEnabled: false,
        databaseEnabled: false,
        geolocationEnabled: false,
        safeBrowsingEnabled: false,
        supportMultipleWindows: false,
        javaScriptCanOpenWindowsAutomatically: false,
        mediaPlaybackRequiresUserGesture: true,
        thirdPartyCookiesEnabled: false,
        saveFormData: false,
        supportZoom: false,
        builtInZoomControls: false,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        cacheMode: CacheMode.LOAD_NO_CACHE,
        isInspectable: kDebugMode,
        transparentBackground: false,
      );
}

/// Used by tests and the example to turn bridge JSON into maps without a WebView.
Map<String, dynamic> decodeReply(String json) => jsonDecode(json) as Map<String, dynamic>;
