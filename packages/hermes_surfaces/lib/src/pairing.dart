import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api.dart';

/// The line a user copies from a chat into the app (`plugin/mobile_surfaces_core/pairing.py`):
///
///     HAP1.<base64url of {"u": <base address of the phone API>, "c": <one-time code>}>
///
/// It carries a one-time code, never the long-lived token. The app shows [host] and asks before it sends
/// anything.
class ConnectionString {
  const ConnectionString._(this.baseUri, this.code);

  final Uri baseUri;
  final String code;

  static const String prefix = 'HAP1.';
  static final RegExp _token = RegExp(r'HAP1\.[A-Za-z0-9_\-=]+');
  static final RegExp _codePattern = RegExp(r'^[A-Za-z0-9_-]{16,200}$');

  /// `host` or `host:port`, for the confirmation question. Never the path (it holds a secret prefix).
  String get host => baseUri.hasPort ? '${baseUri.host}:${baseUri.port}' : baseUri.host;

  /// The first connection string inside [text] (a pasted chat message may carry words around it), or
  /// null when there is none or it is damaged or points somewhere unusable.
  static ConnectionString? tryParse(String? text) {
    final match = text == null ? null : _token.firstMatch(text);
    if (match == null) return null;
    try {
      final body = match.group(0)!.substring(prefix.length).replaceAll('=', '');
      final data = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(body))));
      if (data is! Map) return null;
      final url = data['u'], code = data['c'];
      if (url is! String || code is! String || !_codePattern.hasMatch(code)) return null;
      final uri = Uri.tryParse(url);
      if (uri == null || !ServerConfig.isValidBaseUri(uri)) return null;
      return ConnectionString._(uri, code);
    } on FormatException {
      return null;
    }
  }
}

/// What the server gave back for a spent code.
class ClaimResult {
  const ClaimResult(this.token, {required this.approverPaired});

  final String token;

  /// Whether this phone's key is now the one that confirms publications and deletions.
  final bool approverPaired;
}

/// Spends a connection code: the one request that carries no bearer, because getting one is its purpose.
/// Errors are the same types the rest of the API raises: [OfflineException] when nothing answered,
/// [ApiException] for a refusal (400 wrong or expired code, 404 an older server, 429 too many attempts).
Future<ClaimResult> claimConnectionCode({
  required Uri baseUri,
  required String code,
  required String deviceId,
  required String publicKeyBase64,
  http.Client? client,
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (!ServerConfig.isValidBaseUri(baseUri)) throw ArgumentError('Surfaces base URI is not usable');
  final path = baseUri.normalizePath().path.replaceFirst(RegExp(r'/+$'), '');
  final request = http.Request('POST', baseUri.replace(path: '$path$apiPrefix/devices/claim'))
    ..followRedirects = false
    ..headers['Content-Type'] = 'application/json'
    ..headers['Accept'] = 'application/json'
    ..body = jsonEncode({'code': code, 'deviceId': deviceId, 'publicKey': publicKeyBase64});
  final http.Response res;
  final own = client ?? http.Client();
  try {
    res = await own.send(request).then(http.Response.fromStream).timeout(timeout);
  } on SocketException catch (e) {
    throw OfflineException(e);
  } on TimeoutException catch (e) {
    throw OfflineException(e);
  } on http.ClientException catch (e) {
    throw OfflineException(e);
  } on TlsException catch (e) {
    throw OfflineException(e);
  } on HttpException catch (e) {
    throw OfflineException(e);
  } finally {
    if (client == null) own.close();
  }
  if (res.statusCode >= 300 && res.statusCode < 400) {
    throw ApiException(res.statusCode, 'Surfaces API redirects are not allowed');
  }
  if (res.statusCode >= 400) {
    var message = res.reasonPhrase ?? 'HTTP ${res.statusCode}';
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Map && body['error'] is String) message = body['error'] as String;
      if (body is Map && body['detail'] is String) message = body['detail'] as String;
    } catch (_) {}
    throw ApiException(res.statusCode, message);
  }
  try {
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final token = body is Map ? body['token'] : null;
    final paired = body is Map ? body['approverPaired'] : null;
    if (token is! String || token.trim().isEmpty || token.length > 512 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(token)) {
      throw const FormatException('no usable token');
    }
    return ClaimResult(token.trim(), approverPaired: paired == true);
  } on FormatException {
    // A 200 that is not what the plugin sends came from a portal or a proxy: no answer from the plugin.
    throw OfflineException(const FormatException('Surfaces API answered with an unexpected body'));
  }
}
