import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

ServerConfig config({
  String base = 'https://surfaces.example/pilot/',
  String token = 'alice-surfaces-token',
  String deviceId = 'device-1',
  String? connectionId = 'connection-1',
  String? profileId = 'alice',
  String? credentialGeneration = 'generation-1',
  String scopeSuffix = '',
}) => ServerConfig(
  baseUri: Uri.parse(base),
  token: token,
  deviceId: deviceId,
  connectionId: connectionId,
  profileId: profileId,
  credentialGeneration: credentialGeneration,
  scopeSuffix: scopeSuffix,
);

http.Response jsonResponse(Object body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});

Map<String, dynamic> manifest({bool preview = false}) => {
  'appId': 'zhkh', 'title': 'ЖКХ', 'revision': 7, 'epoch': 'e1',
  'bundle': {'bundleId': 'sha256:${'a' * 64}', 'size': 3, 'format': 1, 'sdkMajor': 1, 'capabilities': <String>[]},
  if (preview) 'preview': {'buildId': 'build_1', 'baseRevision': 3},
};

void main() {
  group('native cache binding', () {
    test('legacy constructor defaults remain optional', () {
      final legacy = ServerConfig(baseUri: Uri.parse('http://127.0.0.1:8787'), token: 'tok', deviceId: 'dev');
      expect(legacy.connectionId, isNull);
      expect(legacy.profileId, isNull);
      expect(legacy.credentialGeneration, isNull);
      expect(legacy.scopeSuffix, '');
      expect(legacy.scope, matches(RegExp(r'^surfaces_v1_[0-9a-f]{64}$')));
    });

    test('same host isolates every binding component, including null and empty', () {
      final bindings = [
        config(),
        config(connectionId: 'connection-2'), config(connectionId: null), config(connectionId: ''),
        config(profileId: 'bob'), config(profileId: null), config(profileId: ''),
        config(credentialGeneration: 'generation-2'),
        config(credentialGeneration: null), config(credentialGeneration: ''),
        config(token: 'bob-surfaces-token'),
        config(base: 'http://surfaces.example:443/pilot/'),
        config(base: 'https://surfaces.example:8443/pilot/'),
        config(base: 'https://surfaces.example/other/'),
        config(base: 'https://surfaces.example/Pilot/'),
        config(scopeSuffix: '_partition-a'), config(scopeSuffix: '_partition_a'),
      ];
      expect(bindings.map((c) => c.scope).toSet(), hasLength(bindings.length));
    });

    test('token owners without native IDs are isolated, even with a fixed generation', () {
      for (final generation in <String?>[null, 'persisted-generation']) {
        final alice = config(connectionId: null, profileId: null, credentialGeneration: generation);
        final bob = config(connectionId: null, profileId: null, credentialGeneration: generation, token: 'replacement-token');
        expect(alice.scope, isNot(bob.scope));
      }
    });

    test('canonical field boundaries cannot alias', () {
      expect(config(connectionId: 'a|b', profileId: 'c').scope,
          isNot(config(connectionId: 'a', profileId: 'b|c').scope));
    });

    test('equivalent scheme, host, default port and trailing slash forms agree', () {
      for (final forms in [
        ['https://surfaces.example/pilot', 'HTTPS://SURFACES.EXAMPLE:443/pilot/',
          'https://Surfaces.Example/pilot///', 'https://surfaces.example/old/../pilot/'],
        ['http://surfaces.example/pilot', 'HTTP://SURFACES.EXAMPLE:80/pilot/'],
        ['https://surfaces.example', 'https://surfaces.example:443/'],
      ]) {
        expect(forms.map((base) => config(base: base).scope).toSet(), hasLength(1));
      }
    });

    test('scopes expose no plaintext address, owner, suffix, generation or token', () {
      final c = config(scopeSuffix: '_private-suffix');
      for (final scope in [c.scope, c.forPreview().scope]) {
        expect(scope, matches(RegExp(r'^surfaces_v1_[0-9a-f]{64}$')));
        for (final privateValue in [c.token, c.baseUri.host, 'pilot', c.connectionId!, c.profileId!,
          c.credentialGeneration!, c.scopeSuffix]) {
          expect(scope, isNot(contains(privateValue)));
        }
      }
    });

    test('exact persisted recreation reopens the same snapshots after restart', () async {
      final root = await Directory.systemTemp.createTemp('surfaces_scope');
      addTearDown(() => root.delete(recursive: true));
      final first = config(scopeSuffix: '_partition');
      final saved = jsonDecode(jsonEncode({
        'baseUri': first.baseUri.toString(), 'token': first.token, 'deviceId': first.deviceId,
        'connectionId': first.connectionId, 'profileId': first.profileId,
        'credentialGeneration': first.credentialGeneration, 'scopeSuffix': first.scopeSuffix,
      })) as Map<String, dynamic>;
      final recreated = ServerConfig(
        baseUri: Uri.parse(saved['baseUri'] as String), token: saved['token'] as String,
        deviceId: saved['deviceId'] as String, connectionId: saved['connectionId'] as String?,
        profileId: saved['profileId'] as String?, credentialGeneration: saved['credentialGeneration'] as String?,
        scopeSuffix: saved['scopeSuffix'] as String,
      );
      await SnapshotCache(Directory('${root.path}/${first.scope}')).put('zhkh', 'query',
          Snapshot(fetchedAt: DateTime.utc(2026, 10, 14), dataRev: 5, results: {'q': 'saved'}));
      expect(recreated.scope, first.scope);
      expect(recreated.forPreview().scope, first.forPreview().scope);
      final reopened = await SnapshotCache(Directory('${root.path}/${recreated.scope}')).get('zhkh', 'query');
      expect(reopened!.results, {'q': 'saved'});
    });

    test('device identity stays outside the cache binding', () {
      expect(config(deviceId: 'device-2').scope, config().scope);
    });

    test('preview preserves the complete binding and cannot alias caller suffixes', () {
      for (final suffix in ['', '_preview', '_custom', '_custom_preview']) {
        final published = config(scopeSuffix: suffix);
        final preview = published.forPreview();
        expect(preview.baseUri, published.baseUri);
        expect(preview.token, published.token);
        expect(preview.deviceId, published.deviceId);
        expect(preview.connectionId, published.connectionId);
        expect(preview.profileId, published.profileId);
        expect(preview.credentialGeneration, published.credentialGeneration);
        expect(preview.scopeSuffix, suffix);
        expect(preview.scope, isNot(published.scope));
        expect(preview.forPreview().scope, preview.scope);
        expect(AppOrigin.forApp(preview.scope, 'zhkh').origin,
            isNot(AppOrigin.forApp(published.scope, 'zhkh').origin));
      }
      final scopes = ['', '_preview', '_custom', '_custom_preview'].expand((suffix) {
        final c = config(scopeSuffix: suffix);
        return [c.scope, c.forPreview().scope];
      });
      expect(scopes.toSet(), hasLength(8));
      expect(config(connectionId: 'connection-2').forPreview().scope, isNot(config().forPreview().scope));
      expect(config(profileId: null).forPreview().profileId, isNull);
      expect(config(profileId: '').forPreview().profileId, '');
    });

    test('legacy published and preview directories are left untouched and never adopted', () async {
      final root = await Directory.systemTemp.createTemp('surfaces_legacy');
      addTearDown(() => root.delete(recursive: true));
      for (final name in ['surfaces_example_443', 'surfaces_example_443_preview']) {
        final legacyRoot = Directory('${root.path}/$name');
        await SnapshotCache(legacyRoot).put('zhkh', 'query',
            Snapshot(fetchedAt: DateTime.utc(2026, 10, 14), dataRev: 1, results: {'q': 'legacy'}));
        await File('${legacyRoot.path}/installed-marker').writeAsString('legacy bundle');
      }
      for (final c in [config(), config().forPreview()]) {
        final newRoot = Directory('${root.path}/${c.scope}');
        expect(await SnapshotCache(newRoot).get('zhkh', 'query'), isNull);
        expect(await newRoot.exists(), isFalse);
      }
      expect(await root.list().length, 2);
      for (final name in ['surfaces_example_443', 'surfaces_example_443_preview']) {
        final legacyRoot = Directory('${root.path}/$name');
        expect(await File('${legacyRoot.path}/installed-marker').readAsString(), 'legacy bundle');
        expect((await SnapshotCache(legacyRoot).get('zhkh', 'query'))!.results, {'q': 'legacy'});
      }
    });
  });

  group('Surfaces API transport', () {
    for (final base in ['http://127.0.0.1:8787', 'http://127.0.0.1:8787/',
      'https://surfaces.example/pilot', 'https://surfaces.example/pilot/',
      'https://surfaces.example/pilot%20space/tenant%2Fone/']) {
      test('all API routes retain base path, queries and encoded bundles at $base', () async {
        final seen = <http.Request>[];
        final binding = config(base: base);
        final mock = MockClient((request) async {
          seen.add(request);
          if (request.url.path.contains('/bundles/')) return http.Response.bytes([1, 2, 3], 200);
          if (request.url.path.endsWith('/apps/zhkh')) return jsonResponse(manifest());
          if (request.url.path.endsWith('/previews/zhkh')) return jsonResponse(manifest(preview: true));
          return jsonResponse({'apps': <Object>[], 'previews': <Object>[]});
        });
        final api = SurfacesApi(binding, client: mock);
        final preview = PreviewApi(binding.forPreview(), client: mock);
        addTearDown(api.close);
        final bundleId = 'sha256:${'a' * 64}';
        const epoch = 'epoch +/?&=Ж';
        await api.health();
        await api.hello(sdkMajor: 1, timezone: 'UTC');
        await api.listApps();
        await api.manifest('zhkh');
        expect(await api.fetchBundle('zhkh', bundleId), [1, 2, 3]);
        await api.queryGroup('zhkh', 7, [{'name': 'q'}], timezone: 'UTC');
        await api.events(since: 42, epoch: epoch);
        await api.pair(deviceId: 'device-1', publicKeyBase64: 'public-key');
        await api.previews();
        await api.challenge('zhkh');
        await api.approve('zhkh', buildId: 'build_1', nonce: 'nonce', signature: 'signature');
        await api.reject('zhkh', buildId: 'build_1');
        await preview.manifest('zhkh');
        await preview.fetchBundle('zhkh', bundleId);
        await preview.queryGroup('zhkh', 7, [{'name': 'q'}], timezone: 'UTC');

        final prefix = '${binding.baseUri.path.replaceFirst(RegExp(r'/+$'), '')}$apiPrefix';
        final encoded = Uri.encodeComponent(bundleId);
        expect(seen.map((r) => '${r.method} ${r.url.path}'), [
          'GET $prefix/health', 'POST $prefix/devices/hello', 'GET $prefix/apps',
          'GET $prefix/apps/zhkh', 'GET $prefix/apps/zhkh/bundles/$encoded', 'POST $prefix/apps/zhkh/data',
          'GET $prefix/events', 'POST $prefix/devices/pair', 'GET $prefix/previews',
          'POST $prefix/previews/zhkh/challenge', 'POST $prefix/previews/zhkh/approve',
          'POST $prefix/previews/zhkh/reject', 'GET $prefix/previews/zhkh',
          'GET $prefix/previews/zhkh/bundles/$encoded', 'POST $prefix/previews/zhkh/data',
        ]);
        expect(seen[6].url.queryParameters, {'since': '42', 'epoch': epoch});
        expect(seen[4].url.toString(), contains('/bundles/sha256%3A'));
        expect(seen[4].url.toString(), isNot(contains('%253A')));
        expect(jsonDecode(seen[5].body), {'revision': 7, 'timezone': 'UTC', 'queries': [{'name': 'q'}]});
        for (final request in seen) {
          expect(request.url.origin, binding.baseUri.origin);
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer ${binding.token}');
          expect(request.headers['X-Device-Id'], binding.deviceId);
          expect(request.headers.values, isNot(contains(binding.profileId)));
          expect(request.headers.values, isNot(contains(binding.credentialGeneration)));
        }
      });
    }

    for (final entry in <String, List<String>>{
      'user info': ['http://owner:uri-secret@surfaces.example/pilot/',
        'https://uri-secret@surfaces.example/pilot/', 'https://owner:uri%2Dsecret@surfaces.example/'],
      'query': ['https://surfaces.example/pilot/?credential=uri-secret',
        'http://127.0.0.1:8787/pilot/?', 'https://surfaces.example/?credential=uri-secret#uri-secret'],
      'fragment': ['https://surfaces.example/pilot/#uri-secret', 'http://127.0.0.1:8787/pilot/#'],
      'scheme or authority': ['ftp://surfaces.example/uri-secret', 'ws://surfaces.example/uri-secret',
        'file:///uri-secret', 'data:text/plain,uri-secret', '//surfaces.example/uri-secret',
        '/uri-secret', 'https:///uri-secret', 'http:uri-secret', 'http://', ''],
    }.entries) {
      test('invalid base ${entry.key} fails before scopes or requests without exposing credentials', () async {
        const token = 'native-surfaces-secret';
        final sanitized = isA<ArgumentError>()
            .having((e) => e.message, 'message',
                'Surfaces base URI must be absolute HTTP(S) with a host and no user info, query or fragment')
            .having((e) => e.invalidValue, 'invalid value', isNull)
            .having((e) => e.toString(), 'error text',
                allOf(isNot(contains('uri-secret')), isNot(contains(token)), isNot(contains('surfaces.example'))));
        var requests = 0;
        for (final base in entry.value) {
          final binding = config(base: base, token: token);
          expect(() => binding.scope, throwsA(sanitized));
          expect(() => binding.forPreview().scope, throwsA(sanitized));
          final client = MockClient((_) async {
            requests++;
            return jsonResponse({});
          });
          final api = SurfacesApi(binding, client: client);
          final preview = PreviewApi(binding.forPreview(), client: client);
          try {
            await expectLater(api.health(), throwsA(sanitized));
            // Supplying an API query cannot bypass validation by replacing the base query.
            await expectLater(api.events(since: 1, epoch: 'e'), throwsA(sanitized));
            await expectLater(api.hello(sdkMajor: 1, timezone: 'UTC'), throwsA(sanitized));
            await expectLater(preview.manifest('zhkh'), throwsA(sanitized));
          } finally {
            api.close();
          }
        }
        expect(requests, 0);
      });
    }

    for (final status in [300, 301, 302, 303, 304, 307, 308, 399]) {
      test('injected client receives no-follow and 3xx $status is a controlled API error', () async {
        var requests = 0;
        final api = SurfacesApi(config(), client: MockClient((request) async {
          requests++;
          expect(request.followRedirects, isFalse);
          return http.Response('not JSON', status,
              headers: {'location': 'https://foreign.example/dashboard?credential=private'});
        }));
        addTearDown(api.close);
        await expectLater(api.health(), throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', status)
            .having((e) => e.message, 'message', 'Surfaces API redirects are not allowed')));
        expect(requests, 1);
      });
    }

    test('socket errors and timeouts retain offline classification', () async {
      final socketApi = SurfacesApi(config(), client: MockClient((_) async => throw const SocketException('offline')));
      final timeoutApi = SurfacesApi(config(), timeout: const Duration(milliseconds: 10),
          client: MockClient((_) => Completer<http.Response>().future));
      addTearDown(socketApi.close);
      addTearDown(timeoutApi.close);
      await expectLater(socketApi.health(), throwsA(isA<OfflineException>()));
      await expectLater(timeoutApi.health(), throwsA(isA<OfflineException>()));
    });

    // Review finding 7: no usable answer from the server is "offline" (stored data may be shown);
    // an answer from the server, even a bad one, never is.
    const portal = 'secret-portal-marker';
    final thrown = <String, Future<http.Response> Function(http.BaseRequest)>{
      'TLS handshake failure': (_) async => throw const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
      'untrusted certificate': (_) async => throw const CertificateException('self signed'),
      'generic TLS failure': (_) async => throw const TlsException('tls'),
      'raw HTTP protocol error': (_) async => throw const HttpException('Connection closed before full header'),
    };
    final badBody = <String, Future<http.Response> Function(http.BaseRequest)>{
      'captive portal HTML with status 200': (_) async =>
          http.Response('<html><body>$portal</body></html>', 200, headers: {'content-type': 'text/html'}),
      'empty body with status 200': (_) async => http.Response('', 200),
      'invalid UTF-8 with status 200': (_) async => http.Response.bytes([0xff, 0xfe, 0x00], 200),
      'truncated JSON with status 200': (_) async => http.Response('{"apps": [', 200),
    };
    final jsonCalls = <String, Future<Object?> Function(SurfacesApi)>{
      'health': (a) => a.health(),
      'hello': (a) => a.hello(sdkMajor: 1, timezone: 'UTC'),
      'listApps': (a) => a.listApps(),
      'queryGroup': (a) => a.queryGroup('zhkh', 7, [{'name': 'q'}], timezone: 'UTC'),
      'events': (a) => a.events(since: 0, epoch: ''),
      'previews': (a) => a.previews(),
    };
    for (final failure in {...thrown, ...badBody}.entries) {
      for (final call in jsonCalls.entries) {
        test('${failure.key} on ${call.key} is offline and exposes nothing from the reply', () async {
          final api = SurfacesApi(config(), client: MockClient((r) async => failure.value(r)));
          addTearDown(api.close);
          await expectLater(
            call.value(api),
            throwsA(isA<OfflineException>().having((e) => e.toString(), 'text', isNot(contains(portal)))),
          );
        });
      }
    }
    for (final failure in thrown.entries) {
      test('${failure.key} on the manifest and the bundle download is offline too', () async {
        final api = SurfacesApi(config(), client: MockClient((r) async => failure.value(r)));
        addTearDown(api.close);
        await expectLater(api.manifest('zhkh'), throwsA(isA<OfflineException>()));
        await expectLater(api.fetchBundle('zhkh', 'sha256:${'a' * 64}'), throwsA(isA<OfflineException>()));
        await expectLater(PreviewApi(config(), client: MockClient((r) async => failure.value(r))).manifest('zhkh'),
            throwsA(isA<OfflineException>()));
      });
    }
    for (final failure in badBody.entries) {
      test('${failure.key} as a manifest stays a controlled manifest refusal, not offline', () async {
        final api = SurfacesApi(config(), client: MockClient((r) async => failure.value(r)));
        addTearDown(api.close);
        await expectLater(api.manifest('zhkh'), throwsA(isA<ManifestException>()));
      });
    }

    for (final status in [401, 403, 404, 409, 422, 500, 502, 503]) {
      test('a real server answer with status $status stays an API error, whatever its body', () async {
        final api = SurfacesApi(config(), client: MockClient((_) async =>
            http.Response('<html>$portal</html>', status, headers: {'content-type': 'text/html'})));
        addTearDown(api.close);
        for (final call in jsonCalls.entries) {
          await expectLater(
            call.value(api),
            throwsA(isA<ApiException>()
                .having((e) => e.status, 'status', status)
                .having((e) => e.message, 'message', isNot(contains(portal)))),
            reason: call.key,
          );
        }
      });
    }

    test('a JSON error body still supplies the message and stays an API error', () async {
      final api = SurfacesApi(config(), client: MockClient((_) async => http.Response('{"error":"stale revision"}', 409)));
      addTearDown(api.close);
      await expectLater(api.health(), throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 409)
          .having((e) => e.message, 'message', 'stale revision')));
    });

    for (final owned in [false, true]) {
      for (final status in [301, 302]) {
        for (final crossOrigin in [false, true]) {
          test('loopback ${owned ? 'injected owned' : 'default native'} $status '
              '${crossOrigin ? 'cross-origin' : 'same-origin'} redirect sends no second request', () async {
            final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            addTearDown(() => foreign.close(force: true));
            addTearDown(() => source.close(force: true));
            final sourcePaths = <String>[];
            final sourceAuth = <String?>[];
            final foreignAuth = <String?>[];
            foreign.listen((request) async {
              foreignAuth.add(request.headers.value(HttpHeaders.authorizationHeader));
              await request.drain<void>();
              request.response.write('{}');
              await request.response.close();
            });
            source.listen((request) async {
              sourcePaths.add(request.uri.path);
              sourceAuth.add(request.headers.value(HttpHeaders.authorizationHeader));
              await request.drain<void>();
              if (request.uri.path.endsWith('/health') || request.uri.path.endsWith('/hello')) {
                request.response.statusCode = status;
                request.response.headers.set(HttpHeaders.locationHeader,
                    crossOrigin ? 'http://127.0.0.1:${foreign.port}/dashboard' : '/dashboard');
              } else {
                request.response.write('{}');
              }
              await request.response.close();
            });

            // Synthetic Surfaces credential; all sockets are loopback, bypassing environment proxies.
            final native = HttpClient()..findProxy = (_) => 'DIRECT';
            addTearDown(() => native.close(force: true));
            await HttpOverrides.runZoned(() async {
              final api = SurfacesApi(config(base: 'http://127.0.0.1:${source.port}/pilot/'),
                  client: owned ? IOClient(native) : null);
              try {
                for (final call in [api.health, () => api.hello(sdkMajor: 1, timezone: 'UTC')]) {
                  await expectLater(call(), throwsA(isA<ApiException>().having((e) => e.status, 'status', status)));
                }
              } finally {
                api.close();
              }
            }, createHttpClient: (_) => native);
            expect(sourcePaths, ['/pilot$apiPrefix/health', '/pilot$apiPrefix/devices/hello']);
            expect(sourceAuth, ['Bearer alice-surfaces-token', 'Bearer alice-surfaces-token']);
            expect(foreignAuth, isEmpty, reason: 'No Surfaces credential or request may reach the dashboard origin');
          });
        }
      }
    }
  });
}
