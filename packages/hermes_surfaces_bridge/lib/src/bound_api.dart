import 'dart:typed_data';

import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:http/http.dart' as http;

/// Gate both requests AND returned futures. Closing a fake/native transport alone does not
/// guarantee that pending responses stop, or that ReviewClient cannot send after key.sign().
/// PreviewApi's type is retained because SurfacesHost treats its 404 as preview_gone.
SurfacesApi bindApi(SurfacesApi api, bool Function() isActive) =>
    api is PreviewApi ? _BoundPreviewApi(api, isActive) : _BoundApi(api, isActive);

mixin _BindingGate on SurfacesApi {
  SurfacesApi get delegate;
  bool Function() get isActive;
  bool _closed = false;

  void _check() {
    if (_closed || !isActive()) throw OfflineException('Apps connection is no longer active');
  }

  Future<T> _run<T>(Future<T> Function() operation) async {
    _check();
    try {
      final result = await operation();
      _check();
      return result;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> hello({required int sdkMajor, required String timezone}) =>
      _run(() => delegate.hello(sdkMajor: sdkMajor, timezone: timezone));
  @override
  Future<Map<String, dynamic>> health() => _run(delegate.health);
  @override
  Future<List<AppSummary>> listApps() => _run(delegate.listApps);
  @override
  Future<AppManifest> manifest(String appId) => _run(() => delegate.manifest(appId));
  @override
  Future<Uint8List> fetchBundle(String appId, String bundleId) => _run(() => delegate.fetchBundle(appId, bundleId));
  @override
  Future<Map<String, dynamic>> queryGroup(
    String appId,
    int revision,
    List<Map<String, dynamic>> calls, {
    required String timezone,
  }) => _run(() => delegate.queryGroup(appId, revision, calls, timezone: timezone));
  @override
  Future<Map<String, dynamic>> events({required int since, required String epoch}) =>
      _run(() => delegate.events(since: since, epoch: epoch));
  @override
  Future<List<PreviewSummary>> previews() => _run(delegate.previews);
  @override
  Future<Map<String, dynamic>> pair({required String deviceId, required String publicKeyBase64}) =>
      _run(() => delegate.pair(deviceId: deviceId, publicKeyBase64: publicKeyBase64));
  @override
  Future<Map<String, dynamic>> challenge(String appId) => _run(() => delegate.challenge(appId));
  @override
  Future<Map<String, dynamic>> approve(
    String appId, {
    required String buildId,
    required String nonce,
    required String signature,
  }) => _run(() => delegate.approve(appId, buildId: buildId, nonce: nonce, signature: signature));
  @override
  Future<void> reject(String appId, {required String buildId}) => _run(() => delegate.reject(appId, buildId: buildId));
  @override
  Future<Map<String, dynamic>> deleteChallenge(String appId) => _run(() => delegate.deleteChallenge(appId));
  @override
  Future<void> deleteApp(String appId, {required String nonce, required String signature}) =>
      _run(() => delegate.deleteApp(appId, nonce: nonce, signature: signature));

  // Files. Each of these MUST delegate: the bound object's own transport is a stub that fails, which the page used to
  // see as an unexplained `host error` (a StateError, not one of this layer's exceptions).
  @override
  Future<StoredFile> uploadFile(
    String appId, {
    required String name,
    required Stream<List<int>> bytes,
    required int length,
  }) => _run(() => delegate.uploadFile(appId, name: name, bytes: bytes, length: length));
  @override
  Future<List<StoredFile>> listFiles(String appId) => _run(() => delegate.listFiles(appId));
  @override
  Future<DownloadedFile> downloadStored(String appId, String fileId) =>
      _run(() => delegate.downloadStored(appId, fileId));
  @override
  Future<DownloadedFile> downloadNamed(
    String appId,
    int revision,
    String locator,
    Map<String, dynamic>? args, {
    required String timezone,
  }) => _run(() => delegate.downloadNamed(appId, revision, locator, args, timezone: timezone));
  @override
  Future<void> deleteFile(String appId, String fileId) => _run(() => delegate.deleteFile(appId, fileId));

  // Buttons that write: forwarded for the same reason as the files above.
  @override
  Future<Map<String, dynamic>> mutate(
    String appId,
    int revision,
    String name,
    Map<String, dynamic> args, {
    required String key,
    required String timezone,
  }) => _run(() => delegate.mutate(appId, revision, name, args, key: key, timezone: timezone));

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    delegate.close();
  }
}

class _BoundApi extends SurfacesApi with _BindingGate {
  _BoundApi(this.delegate, this.isActive) : super(delegate.config, client: _UnusedClient());
  @override
  final SurfacesApi delegate;
  @override
  final bool Function() isActive;
}

class _BoundPreviewApi extends PreviewApi with _BindingGate {
  _BoundPreviewApi(this.delegate, this.isActive) : super(delegate.config, client: _UnusedClient());
  @override
  final SurfacesApi delegate;
  @override
  final bool Function() isActive;
}

// The superclass needs a client, but all methods delegate; never allocate a second transport.
class _UnusedClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(StateError('Bound API must delegate requests'));
}
