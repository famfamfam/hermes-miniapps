// The bound API stands in for the real one while an Apps connection is current. Every method of the real API has to
// be forwarded by it: a method it forgets runs on a stub transport that fails, and the page sees "host error".
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/src/bound_api.dart';
import 'package:http/http.dart' as http;

const _fileId = 'f_0123456789abcdef';

StoredFile _stored() => StoredFile(
  fileId: _fileId,
  name: 'a.pdf',
  mime: 'application/pdf',
  size: 3,
  source: 'phone',
  createdAt: '',
);

/// The real API that records every call and never touches a network.
class _Recording extends SurfacesApi {
  _Recording()
    : super(
        ServerConfig(
          baseUri: Uri.parse('https://x.invalid'),
          token: 't',
          deviceId: 'd',
        ),
        client: _Dead(),
      );
  final calls = <String>[];

  @override
  Future<StoredFile> uploadFile(
    String appId, {
    required String name,
    required Stream<List<int>> bytes,
    required int length,
  }) async {
    calls.add('uploadFile $appId $name $length');
    return _stored();
  }

  @override
  Future<List<StoredFile>> listFiles(String appId) async {
    calls.add('listFiles $appId');
    return [_stored()];
  }

  @override
  Future<DownloadedFile> downloadStored(String appId, String fileId) async {
    calls.add('downloadStored $appId $fileId');
    return DownloadedFile(
      name: 'a.pdf',
      mime: 'application/pdf',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
  }

  @override
  Future<DownloadedFile> downloadNamed(
    String appId,
    int revision,
    String locator,
    Map<String, dynamic>? args, {
    required String timezone,
  }) async {
    calls.add('downloadNamed $appId $revision $locator $args $timezone');
    return DownloadedFile(
      name: 'b.pdf',
      mime: 'application/pdf',
      bytes: Uint8List.fromList([4]),
    );
  }

  @override
  Future<void> deleteFile(String appId, String fileId) async =>
      calls.add('deleteFile $appId $fileId');

  @override
  Future<Map<String, dynamic>> mutate(
    String appId,
    int revision,
    String name,
    Map<String, dynamic> args, {
    required String key,
    required String timezone,
  }) async {
    calls.add('mutate $appId $revision $name $args $key $timezone');
    return {'rowsAffected': 1, 'replayed': false};
  }
}

class _Dead extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw StateError('no network in this test');
}

void main() {
  late _Recording inner;
  var active = true;
  late SurfacesApi bound;

  setUp(() {
    inner = _Recording();
    active = true;
    bound = bindApi(inner, () => active);
  });

  test(
    'every file call goes through to the real API, with its arguments',
    () async {
      expect(
        (await bound.uploadFile(
          'utilities',
          name: 'a.pdf',
          bytes: Stream.value([1, 2, 3]),
          length: 3,
        )).fileId,
        _fileId,
      );
      expect((await bound.listFiles('utilities')).single.fileId, _fileId);
      expect((await bound.downloadStored('utilities', _fileId)).name, 'a.pdf');
      expect(
        (await bound.downloadNamed('zhkh', 6, 'receipt_file', {
          'id': 19,
        }, timezone: 'UTC')).name,
        'b.pdf',
      );
      await bound.deleteFile('utilities', _fileId);
      expect(inner.calls, [
        'uploadFile utilities a.pdf 3',
        'listFiles utilities',
        'downloadStored utilities $_fileId',
        'downloadNamed zhkh 6 receipt_file {id: 19} UTC',
        'deleteFile utilities $_fileId',
      ]);
    },
  );

  test('a button that writes goes through to the real API, with its key', () async {
    final out = await bound.mutate(
      'utilities',
      7,
      'mark_paid',
      {'id': 2},
      key: 'k' * 20,
      timezone: 'UTC',
    );
    expect(out, {'rowsAffected': 1, 'replayed': false});
    expect(inner.calls, ['mutate utilities 7 mark_paid {id: 2} ${'k' * 20} UTC']);
  });

  test('a preview API refuses to save, even through the bound one', () async {
    final boundPreview = bindApi(_PreviewRecording(), () => true);
    await expectLater(
      boundPreview.mutate('utilities', 7, 'mark_paid', {
        'id': 2,
      }, key: 'k' * 20, timezone: 'UTC'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)),
    );
  });

  test('once the connection is no longer current, nothing is saved', () async {
    active = false;
    await expectLater(
      bound.mutate('utilities', 7, 'mark_paid', {
        'id': 2,
      }, key: 'k' * 20, timezone: 'UTC'),
      throwsA(isA<OfflineException>()),
    );
    expect(inner.calls, isEmpty);
  });

  test('the same holds for a preview API, which stays a preview API', () async {
    final preview = _PreviewRecording();
    final boundPreview = bindApi(preview, () => true);
    expect(boundPreview, isA<PreviewApi>());
    await expectLater(
      boundPreview.listFiles('utilities'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)),
    );
    expect(
      preview.calls,
      ['listFiles utilities'],
      reason: 'it reached the real preview API, which refuses files itself',
    );
  });

  test(
    'once the connection is no longer current, no file call is forwarded and each reads as "no connection"',
    () async {
      active = false;
      final calls = <Future<Object?> Function()>[
        () => bound.uploadFile(
          'utilities',
          name: 'a.pdf',
          bytes: const Stream.empty(),
          length: 1,
        ),
        () => bound.listFiles('utilities'),
        () => bound.downloadStored('utilities', _fileId),
        () => bound.downloadNamed(
          'zhkh',
          6,
          'receipt_file',
          null,
          timezone: 'UTC',
        ),
        () => bound.deleteFile('utilities', _fileId),
      ];
      for (final call in calls) {
        await expectLater(call(), throwsA(isA<OfflineException>()));
      }
      expect(inner.calls, isEmpty);
    },
  );

  test(
    'a connection that ends while a download is in flight does not deliver the file',
    () async {
      final gate = Completer<void>();
      final slow = _Slow(gate.future);
      final boundSlow = bindApi(slow, () => active);
      final pending = boundSlow.downloadStored('utilities', _fileId);
      active = false;
      gate.complete();
      await expectLater(pending, throwsA(isA<OfflineException>()));
    },
  );
}

class _PreviewRecording extends PreviewApi {
  _PreviewRecording()
    : super(
        ServerConfig(
          baseUri: Uri.parse('https://x.invalid'),
          token: 't',
          deviceId: 'd',
        ).forPreview(),
        client: _Dead(),
      );
  final calls = <String>[];

  @override
  Future<List<StoredFile>> listFiles(String appId) {
    calls.add('listFiles $appId');
    return super.listFiles(appId);
  }
}

class _Slow extends SurfacesApi {
  _Slow(this.wait)
    : super(
        ServerConfig(
          baseUri: Uri.parse('https://x.invalid'),
          token: 't',
          deviceId: 'd',
        ),
        client: _Dead(),
      );
  final Future<void> wait;

  @override
  Future<DownloadedFile> downloadStored(String appId, String fileId) async {
    await wait;
    return DownloadedFile(
      name: 'a.pdf',
      mime: 'application/pdf',
      bytes: Uint8List.fromList([1]),
    );
  }
}
