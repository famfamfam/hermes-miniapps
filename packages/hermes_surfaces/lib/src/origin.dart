import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'bundle_verify.dart' show checkBundlePath;

/// Virtual HTTPS origin of one app in one server scope. Nothing resolves it: every request to
/// it is answered by the host, and the `.invalid` TLD guarantees it never reaches real DNS.
class AppOrigin {
  AppOrigin._(this.host);

  final String host;

  factory AppOrigin.forApp(String scope, String appId) {
    final tag = sha256.convert(utf8.encode(scope)).toString().substring(0, 8);
    // appId allows '_' which is not valid in a host name; '-' is not allowed in appId, so no clash.
    return AppOrigin._('${appId.replaceAll('_', '-')}.$tag.surfaces.invalid');
  }

  /// Exactly what WebView reports as sourceOrigin: scheme and host, no trailing slash.
  String get origin => 'https://$host';

  bool owns(Uri url) => url.scheme == 'https' && url.host == host && (url.port == 443 || url.port == 0);
}

enum RequestVerdict {
  /// Own origin, GET, well-formed: look the path up in the installed bundle.
  serve,

  /// Not this app's origin: answer locally with 403, never reach the network.
  foreign,

  /// Own origin but not a GET.
  badMethod,

  /// The URL cannot be parsed or decoded. Treated exactly like a foreign request.
  malformed,
}

class RequestDecision {
  const RequestDecision(this.verdict, [this.path = '']);
  final RequestVerdict verdict;

  /// Bundle-relative path (empty = entrypoint). Only meaningful for [RequestVerdict.serve].
  final String path;
}

/// Decides what to do with a request the page (or its subresources) started. Total: it never
/// throws, because an exception in the interception callback would hand the request back to the
/// WebView, i.e. fail open. Anything it cannot understand is [RequestVerdict.malformed], which
/// callers must treat as a refusal.
RequestDecision classifyRequest(AppOrigin origin, String rawUrl, String method) {
  try {
    final url = Uri.tryParse(rawUrl);
    if (url == null) return const RequestDecision(RequestVerdict.malformed);
    if (!origin.owns(url)) return const RequestDecision(RequestVerdict.foreign);
    if (method.toUpperCase() != 'GET') return const RequestDecision(RequestVerdict.badMethod);
    // Throws on bytes that are not valid UTF-8 (e.g. "%FF"); Uri.parse itself turns a stray "%"
    // into "%25", so "%zz" arrives here as a literal percent sign.
    var path = Uri.decodeComponent(url.path);
    if (path.startsWith('/')) path = path.substring(1);
    if (path.isNotEmpty) {
      // A path no bundle could ever contain (traversal, "%", backslash, empty segments) is
      // refused outright instead of being left to fail the file lookup later.
      checkBundlePath(path);
    }
    return RequestDecision(RequestVerdict.serve, path);
  } catch (_) {
    return const RequestDecision(RequestVerdict.malformed);
  }
}

/// Locked-down CSP served with every document and asset (ADR-006 §2). One layer of several:
/// request interception, blockNetworkLoads and navigation rules do not depend on it.
const String contentSecurityPolicy = "default-src 'none'; "
    "script-src 'self'; "
    "style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data:; "
    "font-src 'self'; "
    "connect-src 'none'; "
    "frame-src 'none'; "
    "frame-ancestors 'none'; "
    "object-src 'none'; "
    "worker-src 'none'; "
    "manifest-src 'none'; "
    "media-src 'none'; "
    "base-uri 'none'; "
    "form-action 'none'";

const Map<String, String> securityHeaders = {
  'Content-Security-Policy': contentSecurityPolicy,
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Cache-Control': 'no-store',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=()',
};

const Map<String, String> _mime = {
  'html': 'text/html',
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'css': 'text/css',
  'json': 'application/json',
  'svg': 'image/svg+xml',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'ico': 'image/x-icon',
  'woff2': 'font/woff2',
  'woff': 'font/woff',
  'ttf': 'font/ttf',
  'txt': 'text/plain',
};

String mimeFor(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return _mime[ext] ?? 'application/octet-stream';
}

bool isTextMime(String mime) =>
    mime.startsWith('text/') || mime == 'application/json' || mime == 'image/svg+xml';
