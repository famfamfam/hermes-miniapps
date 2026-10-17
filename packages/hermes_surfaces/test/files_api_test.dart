// The file half of the Surfaces API client: what it sends, what it refuses before sending, and how it reads what
// the server answers.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:http/http.dart' as http;

ServerConfig config() => ServerConfig(baseUri: Uri.parse('https://hermes.example/secret/ms'), token: 'tok', deviceId: 'dev');

const id = 'f_0123456789abcdef';

Map<String, Object?> record([String name = 'a.pdf']) => {
      'fileId': id,
      'name': name,
      'mime': 'application/pdf',
      'size': 3,
      'sha256': 'ab' * 32,
      'source': 'phone',
      'createdAt': '2026-10-17T10:00:00Z',
    };

void main() {
  group('safeFileName', () {
    for (final c in <(String, String)>[
      ('receipt.pdf', 'receipt.pdf'),
      ('../../etc/passwd', 'passwd'),
      (r'D:\scans\a.pdf', 'a.pdf'),
      ('..hidden', 'hidden'),
      ('  spaced.pdf  ', 'spaced.pdf'),
      ('bad<>:"|?*name.pdf', 'badname.pdf'),
      ('line\nbreak\u0000.pdf', 'linebreak.pdf'),
      ('', 'file'),
      ('...', 'file'),
      ('/', 'file'),
      ('Квитанция март.pdf', 'Квитанция март.pdf'),
    ]) {
      test('"${c.$1.replaceAll('\n', '\\n')}" becomes "${c.$2}"', () => expect(safeFileName(c.$1), c.$2));
    }

    test('a long name is cut but keeps its extension', () {
      final name = safeFileName('${'x' * 300}.pdf');
      expect(name.length, 120);
      expect(name, endsWith('.pdf'));
      expect(safeFileName('y' * 300).length, 120);
    });
  });

  test('only the ids the server issues are file ids', () {
    expect(isValidFileId(id), isTrue);
    for (final bad in ['', 'f_', 'f_xyz', 'F_0123456789abcdef', 'f_0123456789abcdeg', 'f_0123456789abcdef0', '../f_0123456789abcdef']) {
      expect(isValidFileId(bad), isFalse, reason: bad);
    }
  });

  group('what the server says about a file', () {
    test('a good record is read, and what goes to the page is only the page\'s part', () {
      final f = StoredFile.fromJson({...record('../../x.pdf'), 'path': '/var/lib/x', 'sha256': 'secret'});
      expect(f.name, 'x.pdf');
      expect(f.toJson().keys.toSet(), {'fileId', 'name', 'mime', 'size', 'createdAt'});
    });

    for (final broken in <Map<String, Object?>>[
      {...record(), 'fileId': 'nope'},
      {...record(), 'fileId': 5},
      {...record(), 'name': null},
      {...record(), 'size': '3'},
      {...record()}..remove('mime'),
    ]) {
      test('a record that is not shaped like one is the server\'s fault: $broken', () {
        expect(() => StoredFile.fromJson(broken), throwsA(isA<ApiException>().having((e) => e.status, 'status', 502)));
      });
    }
  });

  group('upload', () {
    test('streams the body with its announced length and the name percent-encoded', () async {
      http.BaseRequest? seen;
      Uint8List? body;
      final api = SurfacesApi(config(), client: _Spy((r, bytes) {
        seen = r;
        body = bytes;
        return http.Response.bytes(utf8.encode(jsonEncode({...record('Квитанция.pdf'), 'duplicate': true})), 200);
      }));
      final stored = await api.uploadFile('utilities',
          name: 'Квитанция.pdf', bytes: Stream.fromIterable([[1], [2, 3]]), length: 3);
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://hermes.example/secret/ms/api/plugins/mobile-surfaces/v1/apps/utilities/files');
      expect(seen!.contentLength, 3);
      expect(seen!.headers['Authorization'], 'Bearer tok');
      expect(Uri.decodeComponent(seen!.headers['X-File-Name']!), 'Квитанция.pdf');
      expect(seen!.headers['X-File-Name'], isNot(contains('К')));
      expect((seen as http.StreamedRequest).followRedirects, isFalse);
      expect(body, [1, 2, 3]);
      expect(stored.duplicate, isTrue);
    });

    test('a body that fails while it is read fails the upload', () async {
      final api = SurfacesApi(config(), client: _Spy((r, bytes) => http.Response(jsonEncode(record()), 200)));
      Stream<List<int>> broken() async* {
        yield [1];
        throw StateError('disk read failed');
      }

      await expectLater(api.uploadFile('utilities', name: 'a.pdf', bytes: broken(), length: 2), throwsA(anything));
    });

    test('a bad app id is refused before anything is sent', () async {
      var sent = false;
      final api = SurfacesApi(config(), client: _Spy((r, b) {
        sent = true;
        return http.Response('{}', 200);
      }));
      await expectLater(
          api.uploadFile('Bad/App', name: 'a.pdf', bytes: const Stream.empty(), length: 1), throwsA(isA<ManifestException>()));
      expect(sent, isFalse);
    });

    test('a redirect is never followed with the credential', () async {
      final api = SurfacesApi(config(), client: _Spy((r, b) => http.Response('', 302, headers: {'location': 'http://evil.example/'})));
      await expectLater(api.uploadFile('utilities', name: 'a.pdf', bytes: Stream.value([1]), length: 1),
          throwsA(isA<ApiException>().having((e) => e.message, 'message', isNot(contains('evil')))));
    });
  });

  group('download', () {
    test('reads the name and type the server gives, and never trusts the name as a path', () async {
      final api = SurfacesApi(config(), client: _Spy((r, b) => http.Response.bytes([9, 8], 200, headers: {
            'content-type': 'Application/PDF; charset=binary',
            'x-file-name': Uri.encodeComponent('../../Квитанция.pdf'),
          })));
      final f = await api.downloadStored('utilities', id);
      expect(f.name, 'Квитанция.pdf');
      expect(f.mime, 'application/pdf');
      expect(f.bytes, [9, 8]);
    });

    test('a name that is not valid percent-encoding falls back to a plain one', () async {
      final api = SurfacesApi(config(), client: _Spy((r, b) => http.Response.bytes([1], 200, headers: {'x-file-name': '%E0%A4%A'})));
      expect((await api.downloadStored('utilities', id)).name, 'file');
    });

    test('a locator goes in the URL percent-encoded and the arguments in the body', () async {
      http.BaseRequest? seen;
      Uint8List? body;
      final api = SurfacesApi(config(), client: _Spy((r, bytes) {
        seen = r;
        body = bytes;
        return http.Response.bytes([1], 200);
      }));
      await api.downloadNamed('utilities', 3, 'receipt_file', {'id': 4}, timezone: 'UTC');
      expect(seen!.url.path, endsWith('/apps/utilities/downloads/receipt_file'));
      expect(jsonDecode(utf8.decode(body!)), {'revision': 3, 'timezone': 'UTC', 'args': {'id': 4}});
      await api.downloadNamed('utilities', 3, 'receipt_file', null, timezone: 'UTC');
      expect(jsonDecode(utf8.decode(body!)), {'revision': 3, 'timezone': 'UTC'});
    });

    test('an id that the server never issues is not looked up', () async {
      var sent = false;
      final api = SurfacesApi(config(), client: _Spy((r, b) {
        sent = true;
        return http.Response('', 200);
      }));
      await expectLater(api.downloadStored('utilities', '../../registry.db'), throwsA(isA<ApiException>()));
      await expectLater(api.deleteFile('utilities', 'nope'), throwsA(isA<ApiException>()));
      expect(sent, isFalse);
    });

    test('the server\'s refusal text comes through', () async {
      final api = SurfacesApi(config(), client: _Spy((r, b) => http.Response('{"error":"the file is outside the folder"}', 400)));
      await expectLater(api.downloadNamed('utilities', 1, 'receipt_file', {'id': 1}, timezone: 'UTC'),
          throwsA(isA<ApiException>().having((e) => e.message, 'message', 'the file is outside the folder')));
    });
  });

  group('a transfer that dies on the wire', () {
    // A real socket, not a mock: the server announces 100 bytes, sends 10 and drops the connection, which is what a
    // service does when it fails after it started to answer.
    Future<HttpServer> cutOff({int status = 200}) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.add(utf8.encode('HTTP/1.1 $status OK\r\ncontent-type: application/pdf\r\ncontent-length: 100\r\n\r\n'));
        socket.add(List.filled(10, 37));
        await socket.flush();
        socket.destroy();
      });
      addTearDown(() => server.close(force: true));
      return server;
    }

    SurfacesApi apiFor(HttpServer server) => SurfacesApi(
      ServerConfig(baseUri: Uri.parse('http://127.0.0.1:${server.port}'), token: 'tok', deviceId: 'dev'),
      client: http.Client(),
    );

    test('a download cut off in the body is "no answer", like any other loss of the connection', () async {
      final api = apiFor(await cutOff());
      await expectLater(
        api.downloadNamed('utilities', 1, 'receipt_file', {'id': 1}, timezone: 'UTC'),
        throwsA(isA<OfflineException>()),
      );
      await expectLater(api.downloadStored('utilities', id), throwsA(isA<OfflineException>()));
    });

    test('so is a reply to a list request that is cut off', () async {
      final api = apiFor(await cutOff());
      await expectLater(api.listFiles('utilities'), throwsA(isA<OfflineException>()));
    });
  });
  test('a build under review moves no file even if asked directly', () async {
    var sent = false;
    final api = PreviewApi(config().forPreview(), client: _Spy((r, b) {
      sent = true;
      return http.Response('{}', 200);
    }));
    for (final call in <Future<Object?> Function()>[
      () => api.uploadFile('utilities', name: 'a.pdf', bytes: Stream.value([1]), length: 1),
      () => api.listFiles('utilities'),
      () => api.downloadStored('utilities', id),
      () => api.downloadNamed('utilities', 1, 'receipt_file', null, timezone: 'UTC'),
      () => api.deleteFile('utilities', id),
    ]) {
      await expectLater(call(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));
    }
    expect(sent, isFalse);
  });
}

/// A client that hands the handler the request and its whole body.
class _Spy extends http.BaseClient {
  _Spy(this.handler);
  final http.Response Function(http.BaseRequest request, Uint8List body) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final res = handler(request, body);
    return http.StreamedResponse(Stream.value(res.bodyBytes), res.statusCode, headers: res.headers, request: request);
  }
}
