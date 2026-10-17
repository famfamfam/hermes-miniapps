import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' show ProxyController, ProxyRule, ProxySettings, WebViewFeature;

import 'strings.dart' show SurfacesText;

/// A loopback listener that accepts every connection and closes it at once.
///
/// All WebView traffic is routed to it (ProxyController override, see SurfaceView). Nothing a
/// page does with the network — fetch, preconnect, dns-prefetch, WebSocket, WebRTC over TCP — can
/// reach a real host: the "proxy" is this socket, and the proxy is what resolves names, so no DNS
/// lookup happens either. Its second job is evidence: every attempt is reported with the host it
/// wanted, which is what the diagnostics sheet shows as "network refused".
///
/// The port is chosen by the OS and bound to 127.0.0.1 only, so no other app can claim it first.
class NetworkSink {
  NetworkSink._(this._server) {
    _sub = _server.listen(_onConnection, onError: (_) {});
  }

  final ServerSocket _server;
  late final StreamSubscription<Socket> _sub;
  final StreamController<String> _attempts = StreamController<String>.broadcast();
  int _count = 0;

  /// Port on 127.0.0.1 to use as the proxy.
  int get port => _server.port;

  /// Number of connections seen so far.
  int get count => _count;

  /// One line per refused connection, e.g. `CONNECT evil.example:443`.
  Stream<String> get attempts => _attempts.stream;

  static Future<NetworkSink> start() async =>
      NetworkSink._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  void _onConnection(Socket socket) {
    _count++;
    var done = false;
    void finish(String line) {
      if (done) return;
      done = true;
      if (!_attempts.isClosed) _attempts.add(line);
      socket.destroy();
    }

    // The first bytes name the destination. A client that sends nothing is closed after 300 ms.
    final timer = Timer(const Duration(milliseconds: 300), () => finish('connection (no request)'));
    socket.listen(
      (data) {
        timer.cancel();
        finish(describeProxyRequest(data));
      },
      onError: (_) => finish('connection (error)'),
      onDone: () {
        timer.cancel();
        finish('connection (closed)');
      },
      cancelOnError: true,
    );
  }

  Future<void> close() async {
    await _sub.cancel();
    await _server.close();
    await _attempts.close();
  }
}

/// Process-wide installation of the sink as the WebView proxy.
///
/// `ProxyController` is global to the app, so this runs once; every SurfaceView only awaits it.
/// Failing to install it is not a degraded mode: callers must refuse to run the page, because
/// resource hints such as `preconnect` open connections that neither CSP `connect-src`, request
/// interception nor `blockNetworkLoads` stop (measured on a device).
class NetworkSeal {
  NetworkSeal._();

  static Future<NetworkSink>? _installed;

  static Future<NetworkSink> install() async {
    final pending = _installed;
    if (pending != null) return pending;
    final attempt = _doInstall();
    _installed = attempt;
    try {
      return await attempt;
    } catch (_) {
      _installed = null; // allow a retry after a failure
      rethrow;
    }
  }

  static Future<NetworkSink> _doInstall() async {
    if (!await WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
      throw const NetworkSealException(
        'This WebView does not support proxy override (PROXY_OVERRIDE)',
        key: SurfacesText.sealNoProxyOverride,
      );
    }
    final sink = await NetworkSink.start();
    try {
      await ProxyController.instance().setProxyOverride(
        settings: ProxySettings(
          proxyRules: [ProxyRule(url: 'http://127.0.0.1:${sink.port}')],
          bypassRules: const [],
          directs: const [],
          bypassSimpleHostnames: false,
          // Without this, localhost and link-local addresses skip the proxy: a page could then
          // reach services on the phone (127.0.0.1) or its link-local network directly.
          removeImplicitRules: true,
          reverseBypassEnabled: false,
        ),
      );
    } catch (e) {
      await sink.close();
      throw NetworkSealException(
        'could not install the WebView proxy: $e',
        key: SurfacesText.sealProxyFailed,
        detail: '$e',
      );
    }
    return sink;
  }
}

class NetworkSealException implements Exception {
  const NetworkSealException(this.message, {this.key, this.detail});

  /// English diagnostic text; interfaces show the localized text for [key] (with [detail]).
  final String message;
  final SurfacesText? key;
  final String? detail;
  @override
  String toString() => 'NetworkSealException: $message';
}

/// Names what an HTTP proxy client asked for, from the first bytes it sent. Total: never throws.
String describeProxyRequest(List<int> bytes) {
  try {
    final head = utf8.decode(bytes.length > 512 ? bytes.sublist(0, 512) : bytes, allowMalformed: true);
    final line = head.split('\r\n').first.trim();
    final m = RegExp(r'^(CONNECT|GET|POST|PUT|HEAD|OPTIONS|DELETE|PATCH)\s+(\S+)').firstMatch(line);
    if (m == null) return 'unrecognised (${bytes.length} bytes)';
    final target = m.group(2)!;
    return '${m.group(1)} ${target.length > 120 ? '${target.substring(0, 120)}…' : target}';
  } catch (_) {
    return 'unrecognised (${bytes.length} bytes)';
  }
}
