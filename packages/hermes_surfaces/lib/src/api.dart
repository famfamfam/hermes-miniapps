import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'approval.dart' show PreviewSummary;
import 'preview.dart';

const String apiPrefix = '/api/plugins/mobile-surfaces/v1';

/// Native Surfaces connection settings. Only [token] is used as the API credential (SR-6).
class ServerConfig {
  const ServerConfig({
    required this.baseUri,
    required this.token,
    required this.deviceId,
    this.scopeSuffix = '',
    this.connectionId,
    this.profileId,
    this.credentialGeneration,
  }) : _isPreview = false;

  const ServerConfig._preview({
    required this.baseUri,
    required this.token,
    required this.deviceId,
    required this.scopeSuffix,
    required this.connectionId,
    required this.profileId,
    required this.credentialGeneration,
  }) : _isPreview = true;

  final Uri baseUri;
  final String token;
  final String deviceId;

  /// Optional persisted native binding. Null and empty identifiers are distinct scopes.
  final String? connectionId;
  final String? profileId;

  /// Optional caller-persisted generation; the token fingerprint is always included as well.
  final String? credentialGeneration;

  /// Caller-selected cache partition, preserved by [forPreview]. Not a preview discriminator:
  /// previews have a separate namespace even if a published caller uses the suffix "_preview".
  final String scopeSuffix;
  final bool _isPreview;

  String get _basePath => baseUri.normalizePath().path.replaceFirst(RegExp(r'/+$'), '');

  // Validate lazily to retain the const constructor. These URL components are not cache
  // identity or Surfaces credentials, and must not survive into an authenticated request.
  void _validateBaseUri() {
    if (!isValidBaseUri(baseUri)) {
      // Do not use ArgumentError.value or include the URI: it may contain credentials.
      throw ArgumentError('Surfaces base URI must be absolute HTTP(S) with a host and no user info, query or fragment');
    }
  }

  /// The rule every Surfaces address obeys, also for an address that has not been saved yet.
  static bool isValidBaseUri(Uri uri) =>
      uri.isAbsolute &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;

  /// Opaque, versioned cache scope. JSON preserves nulls and field boundaries; no address,
  /// owner identifier or credential is exposed in a directory name. Device/approver identity
  /// remains outside this cache binding. Legacy host/port directories are never adopted.
  String get scope {
    _validateBaseUri();
    final canonical = jsonEncode([
      'hermes-surfaces-scope-v1',
      _isPreview ? 'preview' : 'published',
      [baseUri.scheme.toLowerCase(), baseUri.host.toLowerCase(), baseUri.port, _basePath],
      connectionId,
      profileId,
      credentialGeneration,
      sha256.convert(utf8.encode(token)).toString(),
      scopeSuffix,
    ]);
    return 'surfaces_v1_${sha256.convert(utf8.encode(canonical))}';
  }

  ServerConfig forPreview() => _isPreview
      ? this
      : ServerConfig._preview(
          baseUri: baseUri,
          token: token,
          deviceId: deviceId,
          scopeSuffix: scopeSuffix,
          connectionId: connectionId,
          profileId: profileId,
          credentialGeneration: credentialGeneration,
        );
}

/// No route to the plugin: airplane mode, server down, timeout. Distinct from an HTTP error.
class OfflineException implements Exception {
  OfflineException(this.cause);
  final Object cause;
  @override
  String toString() => 'OfflineException: $cause';
}

class ApiException implements Exception {
  ApiException(this.status, this.message, [this.code]);
  final int status;
  final String message;

  /// A stable word from the server where the status alone is ambiguous (several kinds of 409):
  /// `request_key_reused`, `outcome_unknown`. Null for a plain status.
  final String? code;
  bool get isUnauthorized => status == 401 || status == 403;
  bool get isStale => status == 409;
  @override
  String toString() => 'ApiException($status): $message';
}

class AppSummary {
  AppSummary(this.appId, this.title, this.icon, this.revision);
  final String appId;
  final String title;
  final String? icon;
  final int revision;
}

/// Same rule as the server (`^[a-z][a-z0-9_]{1,39}$`). appId ends up in directory names and
/// virtual host names, so it must never be taken from the network unchecked.
final RegExp _appIdPattern = RegExp(r'^[a-z][a-z0-9_]{1,39}$');
final RegExp _bundleIdPattern = RegExp(r'^sha256:[0-9a-f]{64}$');

bool isValidAppId(String id) => _appIdPattern.hasMatch(id);

/// The server's manifest is not shaped as the contract requires. Treated like a bad bundle:
/// an already installed version keeps running.
class ManifestException implements Exception {
  ManifestException(this.message);
  final String message;
  @override
  String toString() => 'ManifestException: $message';
}

/// A button of an app that writes into its data, as the server's manifest describes it.
class MutationInfo {
  const MutationInfo({required this.destructive, required this.confirm, this.label});

  /// It deletes data: the user is always asked first.
  final bool destructive;

  /// The author asked for a confirmation even though nothing is deleted.
  final bool confirm;
  final String? label;
}

class AppManifest {
  AppManifest._(this.raw, this.preview);
  final Map<String, dynamic> raw;
  final PreviewIdentity? preview;

  /// Validates every field the host later relies on. [expectedAppId] is what the caller asked
  /// for; a manifest answering for a different app is refused rather than installed under that id.
  factory AppManifest.parse(Map<String, dynamic> json, {required String expectedAppId}) {
    T need<T>(Map<String, dynamic> m, String key) {
      final v = m[key];
      if (v is! T) throw ManifestException('manifest field "$key" must be $T');
      return v;
    }

    final appId = need<String>(json, 'appId');
    if (!isValidAppId(appId)) throw ManifestException('manifest appId is not a valid id');
    if (appId != expectedAppId) {
      throw ManifestException('manifest is for "$appId", requested "$expectedAppId"');
    }
    need<String>(json, 'title');
    need<int>(json, 'revision');
    need<String>(json, 'epoch');
    final bundle = need<Map<String, dynamic>>(json, 'bundle');
    if (!_bundleIdPattern.hasMatch(need<String>(bundle, 'bundleId'))) {
      throw ManifestException('manifest bundleId is malformed');
    }
    need<int>(bundle, 'size');
    need<int>(bundle, 'format');
    need<int>(bundle, 'sdkMajor');
    final caps = need<List<dynamic>>(bundle, 'capabilities');
    if (caps.any((c) => c is! String)) throw ManifestException('manifest capabilities must be strings');
    if (bundle['contractHash'] != null && bundle['contractHash'] is! String) {
      throw ManifestException('manifest contractHash must be a string');
    }
    PreviewIdentity? preview;
    if (json.containsKey('preview')) {
      try {
        preview = PreviewIdentity.fromJson(json['preview']);
      } on FormatException catch (e) {
        throw ManifestException(e.message);
      }
    }
    return AppManifest._(json, preview);
  }

  /// What the server says about one of this app's buttons that write (never its SQL). Null for a name it does not
  /// list. The words shown to the user come from here, not from the page.
  MutationInfo? mutation(String name) {
    final all = raw['mutations'];
    final m = all is Map ? all[name] : null;
    if (m is! Map) return null;
    final label = m['label'];
    return MutationInfo(
      destructive: m['destructive'] == true,
      confirm: m['confirm'] == true,
      label: label is String && label.trim().isNotEmpty && label.length <= 60 ? label.trim() : null,
    );
  }

  String get appId => raw['appId'] as String;
  String get title => raw['title'] as String;
  int get revision => raw['revision'] as int;
  String get epoch => raw['epoch'] as String;
  Map<String, dynamic> get bundle => raw['bundle'] as Map<String, dynamic>;
  String get bundleId => bundle['bundleId'] as String;
  String get contractHash => (bundle['contractHash'] ?? '') as String;
  int get sdkMajor => bundle['sdkMajor'] as int;
  int get bundleFormat => bundle['format'] as int;
}

class SurfacesApi {
  SurfacesApi(this.config, {http.Client? client, this.timeout = const Duration(seconds: 8)})
      : _client = client ?? http.Client();

  final ServerConfig config;
  final http.Client _client;
  final Duration timeout;

  Uri _uri(String path, [Map<String, String>? query]) {
    config._validateBaseUri();
    return config.baseUri.replace(path: '${config._basePath}$apiPrefix$path', queryParameters: query);
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${config.token}',
        'X-Device-Id': config.deviceId,
        'Accept': 'application/json',
      };

  Future<http.Response> _send(String method, String path, {Map<String, String>? query, String? body}) async {
    // Use send rather than the get/post helpers: both native and injected clients must see
    // followRedirects=false before the credential-bearing request leaves this origin.
    final request = http.Request(method, _uri(path, query))
      ..followRedirects = false
      ..headers.addAll(_headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = body;
    }
    return _transmit(request, timeout);
  }

  /// Sends [request] and turns every failure into this layer's two kinds: [OfflineException] (no answer from the
  /// plugin) and [ApiException] (an answer that is an error). [limit] bounds the whole exchange, body included.
  Future<http.Response> _transmit(http.BaseRequest request, Duration limit) async {
    final http.Response res;
    try {
      res = await _client.send(request).then(http.Response.fromStream).timeout(limit);
    } on SocketException catch (e) {
      throw OfflineException(e);
    } on TimeoutException catch (e) {
      throw OfflineException(e);
    } on http.ClientException catch (e) {
      throw OfflineException(e);
    } on TlsException catch (e) {
      // Handshake and certificate failures (captive portal, intercepting proxy, bad certificate):
      // no answer from the plugin was received, and no credential was sent over that connection.
      throw OfflineException(e);
    } on HttpException catch (e) {
      // Connection closed mid-header and similar protocol failures. These are not server answers:
      // an answer carries a status code and is handled below.
      throw OfflineException(e);
    }
    if (res.statusCode >= 300 && res.statusCode < 400) {
      // Never replay credentials, including to a same-origin redirect. Do not expose Location.
      throw ApiException(res.statusCode, 'Surfaces API redirects are not allowed');
    }
    if (res.statusCode >= 400) {
      var message = res.reasonPhrase ?? 'HTTP ${res.statusCode}';
      String? code;
      try {
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        if (body is Map && body['error'] is String) message = body['error'] as String;
        if (body is Map && body['detail'] is String) message = body['detail'] as String;
        if (body is Map && body['code'] is String && RegExp(r'^[a-z_]{1,40}$').hasMatch(body['code'] as String)) {
          code = body['code'] as String;
        }
      } catch (_) {}
      throw ApiException(res.statusCode, message, code);
    }
    return res;
  }

  Map<String, dynamic> _json(http.Response res) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      // A 200 that is not JSON came from a captive portal or a proxy, not from the plugin. Treated
      // like no answer. The FormatException is dropped on purpose: its text quotes the body.
      throw OfflineException(const FormatException('Surfaces API answered with a non-JSON body'));
    }
    return decoded as Map<String, dynamic>;
  }

  AppManifest _parseManifest(http.Response res, {required String appId}) {
    try {
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is! Map<String, dynamic>) throw ManifestException('manifest must be a JSON object');
      return AppManifest.parse(json, expectedAppId: appId);
    } on FormatException catch (e) {
      throw ManifestException('manifest is not valid JSON: ${e.message}');
    }
  }

  Future<Map<String, dynamic>> health() async => _json(await _send('GET', '/health'));

  Future<Map<String, dynamic>> hello({required int sdkMajor, required String timezone}) async {
    final body = jsonEncode({
      'hostVersion': '0.0.1',
      'sdkMajor': sdkMajor,
      'bundleFormat': 1,
      'capabilities': <String>[],
      'timezone': timezone,
    });
    return _json(await _send('POST', '/devices/hello', body: body));
  }

  Future<List<AppSummary>> listApps() async {
    final json = _json(await _send('GET', '/apps'));
    return (json['apps'] as List)
        .cast<Map<String, dynamic>>()
        .where((a) => a['appId'] is String && isValidAppId(a['appId'] as String))
        .map((a) => AppSummary(a['appId'] as String, a['title'] as String, a['icon'] as String?, a['revision'] as int))
        .toList();
  }

  Future<AppManifest> manifest(String appId) async {
    if (!isValidAppId(appId)) throw ManifestException('not a valid app id');
    final response = await _send('GET', '/apps/$appId');
    return _parseManifest(response, appId: appId);
  }

  Future<Uint8List> fetchBundle(String appId, String bundleId) async {
    final res = await _send('GET', '/apps/$appId/bundles/${Uri.encodeComponent(bundleId)}');
    return res.bodyBytes;
  }

  Future<Map<String, dynamic>> queryGroup(
    String appId,
    int revision,
    List<Map<String, dynamic>> calls, {
    required String timezone,
  }) async {
    final body = jsonEncode({'revision': revision, 'timezone': timezone, 'queries': calls});
    return _json(await _send('POST', '/apps/$appId/data', body: body));
  }

  Future<Map<String, dynamic>> events({required int since, required String epoch}) async =>
      _json(await _send('GET', '/events', query: {'since': '$since', 'epoch': epoch}));

  // -- review (ADR-007 §5) ----------------------------------------------------

  Future<Map<String, dynamic>> pair({required String deviceId, required String publicKeyBase64}) async {
    final body = jsonEncode({'deviceId': deviceId, 'publicKey': publicKeyBase64});
    return _json(await _send('POST', '/devices/pair', body: body));
  }

  Future<List<PreviewSummary>> previews() async {
    final json = _json(await _send('GET', '/previews'));
    final raw = json['previews'];
    if (raw is! List) return const [];
    return raw.map(PreviewSummary.tryParse).whereType<PreviewSummary>().toList();
  }

  Future<Map<String, dynamic>> challenge(String appId) async {
    if (!isValidAppId(appId)) throw ManifestException('not a valid app id');
    return _json(await _send('POST', '/previews/$appId/challenge'));
  }

  Future<Map<String, dynamic>> approve(
    String appId, {
    required String buildId,
    required String nonce,
    required String signature,
  }) async {
    if (!isValidAppId(appId)) throw ManifestException('not a valid app id');
    final body = jsonEncode({'buildId': buildId, 'nonce': nonce, 'signature': signature});
    return _json(await _send('POST', '/previews/$appId/approve', body: body));
  }

  Future<void> reject(String appId, {required String buildId}) async {
    if (!isValidAppId(appId)) throw ManifestException('not a valid app id');
    final body = jsonEncode({'buildId': buildId});
    await _send('POST', '/previews/$appId/reject', body: body);
  }

  // -- deletion of a published app, decided by the paired device ----------------

  Future<Map<String, dynamic>> deleteChallenge(String appId) async {
    if (!isValidAppId(appId)) throw ManifestException('not a valid app id');
    return _json(await _send('POST', '/apps/$appId/delete/challenge'));
  }

  Future<void> deleteApp(String appId, {required String nonce, required String signature}) async {
    if (!isValidAppId(appId)) throw ManifestException('not a valid app id');
    final body = jsonEncode({'nonce': nonce, 'signature': signature});
    await _send('POST', '/apps/$appId/delete', body: body);
  }

  // -- files (ADR-004 §6): bytes never pass through the page; the host moves them -------------------------

  /// A whole file in either direction can take a while on a mobile link; the usual answer timeout is for JSON.
  static const Duration transferTimeout = Duration(minutes: 3);

  /// Stores [bytes] ([length] of them) as a file of [appId]. The server decides whether it is acceptable; the same
  /// content sent twice is one file (`duplicate`), so a retry after a lost answer is safe.
  Future<StoredFile> uploadFile(
    String appId, {
    required String name,
    required Stream<List<int>> bytes,
    required int length,
  }) async {
    _checkAppId(appId);
    final request = http.StreamedRequest('POST', _uri('/apps/$appId/files'))
      ..followRedirects = false
      ..contentLength = length
      ..headers.addAll({
        ..._headers,
        'Content-Type': 'application/octet-stream',
        'X-File-Name': Uri.encodeComponent(name),
      });
    unawaited(() async {
      try {
        await request.sink.addStream(bytes);
      } catch (e, s) {
        request.sink.addError(e, s);
      } finally {
        await request.sink.close();
      }
    }());
    return StoredFile.fromJson(_json(await _transmit(request, transferTimeout)), alsoDuplicate: true);
  }

  Future<List<StoredFile>> listFiles(String appId) async {
    _checkAppId(appId);
    final raw = _json(await _send('GET', '/apps/$appId/files'))['files'];
    if (raw is! List) throw ApiException(502, 'unexpected answer to the file list');
    return [for (final f in raw) StoredFile.fromJson(f as Map<String, dynamic>)];
  }

  Future<DownloadedFile> downloadStored(String appId, String fileId) async {
    _checkAppId(appId);
    if (!isValidFileId(fileId)) throw ApiException(404, 'unknown file');
    final request = http.Request('GET', _uri('/apps/$appId/files/$fileId'))
      ..followRedirects = false
      ..headers.addAll(_headers)
      ..headers['Accept'] = '*/*';
    return DownloadedFile.fromResponse(await _transmit(request, transferTimeout));
  }

  /// The file one of the app's file locators names for [args] (a receipt's PDF, for instance). The page supplies
  /// only the locator name and typed arguments; the server decides what, if anything, that points to.
  Future<DownloadedFile> downloadNamed(
    String appId,
    int revision,
    String locator,
    Map<String, dynamic>? args, {
    required String timezone,
  }) async {
    _checkAppId(appId);
    final request = http.Request('POST', _uri('/apps/$appId/downloads/${Uri.encodeComponent(locator)}'))
      ..followRedirects = false
      ..headers.addAll({..._headers, 'Accept': '*/*', 'Content-Type': 'application/json'})
      ..body = jsonEncode({'revision': revision, 'timezone': timezone, 'args': ?args});
    return DownloadedFile.fromResponse(await _transmit(request, transferTimeout));
  }

  Future<void> deleteFile(String appId, String fileId) async {
    _checkAppId(appId);
    if (!isValidFileId(fileId)) throw ApiException(404, 'unknown file');
    await _send('DELETE', '/apps/$appId/files/$fileId');
  }

  // -- buttons that write (ADR-004 §2-3) --------------------------------------------------------------------------

  /// One tap on a button that writes: the app's reviewed mutation [name] with typed [args], at [revision]. The server
  /// runs the SQL it reviewed, never anything the page sent. [key] makes a repeat of the same request (the answer was
  /// lost on the way) change the data once; the caller makes it, one per user action. A lost answer
  /// ([OfflineException]) leaves the outcome unknown, never "not done".
  Future<Map<String, dynamic>> mutate(
    String appId,
    int revision,
    String name,
    Map<String, dynamic> args, {
    required String key,
    required String timezone,
  }) async {
    _checkAppId(appId);
    final body = jsonEncode({
      'revision': revision,
      'timezone': timezone,
      'idempotencyKey': key,
      if (args.isNotEmpty) 'args': args,
    });
    return _json(await _send('POST', '/apps/$appId/mutations/${Uri.encodeComponent(name)}', body: body));
  }

  void _checkAppId(String appId) {
    if (!isValidAppId(appId)) throw ManifestException('not a valid app id');
  }

  void close() => _client.close();
}

final RegExp _fileIdPattern = RegExp(r'^f_[0-9a-f]{16}$');

/// The ids the server issues for stored files. Checked before one is put into a URL or shown to a page.
bool isValidFileId(String id) => _fileIdPattern.hasMatch(id);

/// What the server keeps of a file (`GET /apps/{id}/files`, and the answer to an upload).
class StoredFile {
  StoredFile({
    required this.fileId,
    required this.name,
    required this.mime,
    required this.size,
    required this.source,
    required this.createdAt,
    this.duplicate,
  });

  final String fileId;
  final String name;
  final String mime;
  final int size;
  final String source;
  final String createdAt;

  /// Only in the answer to an upload: the server already had this content.
  final bool? duplicate;

  /// A record from the server. A reply that is not shaped like one is the server's fault, not the user's.
  factory StoredFile.fromJson(Map<String, dynamic> json, {bool alsoDuplicate = false}) {
    final id = json['fileId'], name = json['name'], mime = json['mime'], size = json['size'];
    if (id is! String || !isValidFileId(id) || name is! String || mime is! String || size is! int) {
      throw ApiException(502, 'unexpected file record');
    }
    return StoredFile(
      fileId: id,
      name: safeFileName(name),
      mime: mime,
      size: size,
      source: json['source'] is String ? json['source'] as String : 'phone',
      createdAt: json['createdAt'] is String ? json['createdAt'] as String : '',
      duplicate: alsoDuplicate && json['duplicate'] is bool ? json['duplicate'] as bool : null,
    );
  }

  /// What the page receives. Nothing else about the server leaks into it.
  Map<String, Object?> toJson() => {
        'fileId': fileId,
        'name': name,
        'mime': mime,
        'size': size,
        'createdAt': createdAt,
        if (duplicate != null) 'duplicate': duplicate,
      };
}

/// A file received from the server: the bytes, a safe name to offer and its media type.
class DownloadedFile {
  DownloadedFile({required this.name, required this.mime, required this.bytes});

  final String name;
  final String mime;
  final Uint8List bytes;

  factory DownloadedFile.fromResponse(http.Response res) {
    final raw = res.headers['x-file-name'];
    String decoded = 'file';
    if (raw != null) {
      try {
        decoded = Uri.decodeComponent(raw);
      } on FormatException {
        decoded = 'file';
      } on ArgumentError {
        decoded = 'file'; // a truncated escape ("%E0%A4%A") is reported this way
      }
    }
    final type = (res.headers['content-type'] ?? 'application/octet-stream').split(';').first.trim().toLowerCase();
    return DownloadedFile(name: safeFileName(decoded), mime: type, bytes: res.bodyBytes);
  }
}

/// A plain file name from whatever came over the network: no directories, no control characters or characters a
/// file system dislikes, no leading dots, at most 120 characters, never empty.
String safeFileName(String raw) {
  var name = raw.replaceAll('\\', '/').split('/').last;
  name = name.replaceAll(RegExp(r'[\u0000-\u001f\u007f<>:"|?*]'), '').trim();
  name = name.replaceFirst(RegExp(r'^[. ]+'), '').replaceFirst(RegExp(r'[. ]+$'), '');
  if (name.length > 120) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && name.length - dot <= 9 ? name.substring(dot) : '';
    name = name.substring(0, 120 - ext.length) + ext;
  }
  return name.isEmpty ? 'file' : name;
}

/// The same host machinery pointed at a build awaiting review: manifest, bundle and queries come
/// from the preview routes (the draft's own definitions, read-only). Installed with a separate
/// [ServerConfig.forPreview] scope into a separate store, so nothing published is touched.
class PreviewApi extends SurfacesApi {
  PreviewApi(super.config, {super.client, super.timeout});

  @override
  Future<AppManifest> manifest(String appId) async {
    if (!isValidAppId(appId)) throw ManifestException('not a valid app id');
    final response = await _send('GET', '/previews/$appId');
    final manifest = _parseManifest(response, appId: appId);
    if (manifest.preview == null) throw ManifestException('preview manifest is missing preview metadata');
    return manifest;
  }

  @override
  Future<Uint8List> fetchBundle(String appId, String bundleId) async {
    final res = await _send('GET', '/previews/$appId/bundles/${Uri.encodeComponent(bundleId)}');
    return res.bodyBytes;
  }

  @override
  Future<Map<String, dynamic>> queryGroup(
    String appId,
    int revision,
    List<Map<String, dynamic>> calls, {
    required String timezone,
  }) async {
    final body = jsonEncode({'revision': revision, 'timezone': timezone, 'queries': calls});
    return _json(await _send('POST', '/previews/$appId/data', body: body));
  }

  // A build under review does not move files: the page there is only looked at (the host also refuses
  // the bridge operations first; this is the second lock).
  static ApiException get _noFiles => ApiException(403, 'files are not available in a preview');

  @override
  Future<StoredFile> uploadFile(String appId,
          {required String name, required Stream<List<int>> bytes, required int length}) async =>
      throw _noFiles;

  @override
  Future<List<StoredFile>> listFiles(String appId) async => throw _noFiles;

  @override
  Future<DownloadedFile> downloadStored(String appId, String fileId) async => throw _noFiles;

  @override
  Future<DownloadedFile> downloadNamed(String appId, int revision, String locator, Map<String, dynamic>? args,
          {required String timezone}) async =>
      throw _noFiles;

  @override
  Future<void> deleteFile(String appId, String fileId) async => throw _noFiles;

  // Nor does it save: a preview never changes data, whatever the page asks.
  @override
  Future<Map<String, dynamic>> mutate(String appId, int revision, String name, Map<String, dynamic> args,
          {required String key, required String timezone}) async =>
      throw ApiException(403, 'saving is not available in a preview');
}
