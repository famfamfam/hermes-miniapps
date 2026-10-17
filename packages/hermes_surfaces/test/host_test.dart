import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/src/api.dart';
import 'package:hermes_surfaces/src/approval.dart';
import 'package:hermes_surfaces/src/bundle_store.dart';
import 'package:hermes_surfaces/src/bundle_verify.dart';
import 'package:hermes_surfaces/src/host.dart';
import 'package:hermes_surfaces/src/preview.dart';
import 'package:hermes_surfaces/src/snapshots.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final Directory fixtures = Directory('../../contracts/fixtures/bundles');
final index = jsonDecode(File('${fixtures.path}/index.json').readAsStringSync()) as Map<String, dynamic>;

List<int> zipOf(String name) => File('${fixtures.path}/${index[name]['file']}').readAsBytesSync();
String idOf(String name) => index[name]['bundleId'] as String;

/// A snapshot store whose disk is full: every write fails.
class _FullDiskSnapshots extends SnapshotCache {
  _FullDiskSnapshots(super.root);
  int attempts = 0;

  @override
  Future<void> put(String appId, String key, Snapshot s) async {
    attempts++;
    throw const FileSystemException('No space left on device');
  }
}

/// A fake plugin server whose behaviour tests switch at will.
class FakeServer {
  String bundleName = 'good';
  String manifestAppId = 'utilities';
  int revision = 1;
  int sdkMajor = 1;
  bool online = true;
  int status = 200; // forced status for /data
  int bundleDownloads = 0;
  int dataRev = 10;
  bool previewGone = false;
  bool includePreviewMetadata = true;
  Object? previewMetadata = {
    'buildId': 'build_1',
    'baseRevision': 0,
    'isNew': true,
    'submittedAt': '2026-10-11T09:30:00Z',
  };
  final List<Map<String, dynamic>> dataRequests = [];

  Future<http.Response> handle(http.Request r) async {
    if (!online) throw const SocketException('network is unreachable');
    var path = r.url.path.replaceFirst('/api/plugins/mobile-surfaces/v1', '');
    final isPreview = path.startsWith('/previews/');
    if (isPreview) {
      if (previewGone) return http.Response('{"error":"nothing is awaiting review for this app"}', 404);
      path = path.replaceFirst('/previews/', '/apps/');
    }
    if (r.headers['Authorization'] != 'Bearer tok') return http.Response('{"detail":"unauthorized"}', 401);
    if (path == '/apps/utilities' || path == '/apps/other') {
      return http.Response(
        jsonEncode({
          'appId': path == '/apps/other' ? 'other' : manifestAppId,
          'title': 'Коммуналка',
          'revision': revision,
          'epoch': 'e1',
          'bundle': {
            'bundleId': idOf(bundleName),
            'size': 1,
            'format': 1,
            'sdkMajor': sdkMajor,
            'capabilities': <String>[],
            'contractHash': 'sha256:c1',
          },
          if (isPreview && includePreviewMetadata) 'preview': previewMetadata,
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (path.startsWith('/apps/utilities/bundles/') || path.startsWith('/apps/other/bundles/')) {
      bundleDownloads++;
      return http.Response.bytes(zipOf(bundleName), 200);
    }
    if (path == '/apps/utilities/data') {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      dataRequests.add(body);
      if (status != 200) return http.Response(jsonEncode({'error': 'stale revision'}), status);
      return http.Response(
        jsonEncode({
          'revision': body['revision'],
          'dataRev': dataRev,
          'epoch': 'e1',
          'results': {
            for (final q in body['queries'])
              q['name']: {
                'data': [q['args']],
                'completeness': 'bounded',
              },
          },
        }),
        200,
      );
    }
    return http.Response('{}', 404);
  }
}

void main() {
  late Directory tmp;
  late FakeServer server;
  late SurfacesHost host;
  late BundleStore bundles;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ms_host_test');
    server = FakeServer();
    final config = ServerConfig(baseUri: Uri.parse('http://127.0.0.1:8787'), token: 'tok', deviceId: 'dev');
    bundles = BundleStore(Directory('${tmp.path}/surfaces/${config.scope}'));
    host = SurfacesHost(
      api: SurfacesApi(config, client: MockClient(server.handle)),
      bundles: bundles,
      snapshots: SnapshotCache(Directory('${tmp.path}/surfaces/${config.scope}')),
      clock: () => DateTime.utc(2026, 10, 11, 9, 30),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('install', () {
    test('first start downloads, verifies and installs; second open reuses it', () async {
      final a = await host.ensureInstalled('utilities');
      expect(a.revision, 1);
      expect(a.bundleId, idOf('good'));
      expect(a.preview, isNull);
      expect(a.files, containsAll(['index.html', 'app.js', 'assets/style.css']));
      expect(server.bundleDownloads, 1);
      await host.ensureInstalled('utilities');
      expect(server.bundleDownloads, 1);
    });

    test('served files are only those listed in bundle.json', () async {
      final a = await host.ensureInstalled('utilities');
      expect(await bundles.read(a, 'index.html'), isNotNull);
      expect(await bundles.read(a, 'bundle.json'), isNull);
      expect(await bundles.read(a, '../installed.json'), isNull);
      expect(await bundles.read(a, '.complete'), isNull);
    });

    test('offline with an installed app opens it; offline on first start explains', () async {
      server.online = false;
      await expectLater(
        host.ensureInstalled('utilities'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'offline_first_start')),
      );
      expect(host.connectivity.value, Connectivity.offline);

      server.online = true;
      await host.ensureInstalled('utilities');
      server.online = false;
      final again = await host.ensureInstalled('utilities');
      expect(again.revision, 1);
    });

    for (final bad in ['hash_mismatch', 'traversal', 'unlisted_file', 'symlink', 'bad_format', 'wrong_bundle_id']) {
      test('a bad update ($bad) leaves the working version running', () async {
        await host.ensureInstalled('utilities');
        server.bundleName = bad;
        server.revision = 2;
        expect(await host.checkForUpdate('utilities'), isNull);
        final still = await bundles.current('utilities');
        expect(still!.revision, 1);
        expect(still.bundleId, idOf('good'));
        expect(await bundles.read(still, 'index.html'), isNotNull);
      });
    }

    test('a bad first install installs nothing', () async {
      server.bundleName = 'hash_mismatch';
      await expectLater(host.ensureInstalled('utilities'), throwsA(isA<BundleException>()));
      expect(await bundles.current('utilities'), isNull);
    });

    test('incompatible SDK is refused before download', () async {
      server.sdkMajor = 9;
      await expectLater(
        host.ensureInstalled('utilities'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'incompatible')),
      );
      expect(server.bundleDownloads, 0);
      expect(await bundles.current('utilities'), isNull);
    });

    test('a failure right before the switch keeps the previous pointer and cleans staging', () async {
      final first = await host.ensureInstalled('utilities');
      final bundle = verifyBundle(Uint8List.fromList(zipOf('good')), expectedId: idOf('good'));
      await expectLater(
        bundles.install(
          'utilities',
          bundle,
          title: 'T',
          revision: 5,
          contractHash: 'x',
          epoch: 'e',
          onBeforeSwitch: () async => throw StateError('form not flushed'),
        ),
        throwsStateError,
      );
      final now = await bundles.current('utilities');
      expect(now!.revision, first.revision);
      expect(
        Directory(
          '${tmp.path}/surfaces',
        ).listSync(recursive: true).whereType<Directory>().where((d) => d.path.contains('staging')),
        isEmpty,
      );
    });

    test('update keeps the previous version and prunes older ones', () async {
      await host.ensureInstalled('utilities');
      server.revision = 2; // same bundle, new revision: pointer moves, no second copy needed
      await host.ensureInstalled('utilities');
      expect((await bundles.current('utilities'))!.revision, 2);
    });

    // Review finding 6: a bad *candidate* must never take down an app that already works.
    for (final bad in ['hash_mismatch', 'traversal', 'unlisted_file', 'manifest_not_object', 'size_not_integer']) {
      test('opening an installed app survives a bad new package ($bad)', () async {
        await host.ensureInstalled('utilities');
        server.bundleName = bad;
        server.revision = 2;
        final opened = await host.ensureInstalled('utilities');
        expect(opened.revision, 1);
        expect(opened.bundleId, idOf('good'));
        expect(host.updateProblems['utilities'], isNotNull);
        expect(await bundles.read(opened, 'index.html'), isNotNull);
      });
    }

    test('opening an installed app survives an incompatible new package', () async {
      await host.ensureInstalled('utilities');
      server.sdkMajor = 9;
      server.revision = 2;
      final opened = await host.ensureInstalled('utilities');
      expect(opened.revision, 1);
      expect(host.updateProblems['utilities'], contains('SDK'));
    });

    test('a later good package clears the recorded problem', () async {
      await host.ensureInstalled('utilities');
      server.bundleName = 'hash_mismatch';
      server.revision = 2;
      await host.ensureInstalled('utilities');
      expect(host.updateProblems, isNotEmpty);
      server.bundleName = 'good';
      server.revision = 3;
      final fixed = await host.ensureInstalled('utilities');
      expect(fixed.revision, 3);
      expect(host.updateProblems, isEmpty);
    });

    // Review finding 2: the appId becomes a directory name, so it must come from the caller.
    for (final evil in ['other', '../../x', '../escape', 'Utilities', 'a/b', '']) {
      test('a manifest for "$evil" is refused and writes nothing', () async {
        server.manifestAppId = evil;
        await expectLater(host.ensureInstalled('utilities'), throwsA(isA<ManifestException>()));
        expect(server.bundleDownloads, 0);
        final created = tmp.listSync(recursive: true).map((e) => e.path.replaceAll('\\', '/'));
        expect(created.where((p) => p.contains('/apps/')), isEmpty, reason: 'nothing may be created');
        expect(created.where((p) => p.endsWith('/x') || p.endsWith('/escape')), isEmpty);
      });
    }

    test('an update that names another app is refused and the installed app keeps running', () async {
      await host.ensureInstalled('utilities');
      server.manifestAppId = 'other';
      server.revision = 2;
      final opened = await host.ensureInstalled('utilities');
      expect(opened.appId, 'utilities');
      expect(opened.revision, 1);
      expect(await bundles.current('other'), isNull);
    });

    test('the store refuses ids that are not plain app ids', () async {
      for (final id in ['../evil', 'a/b', r'a\b', '..', 'UPPER', '']) {
        await expectLater(bundles.current(id), throwsArgumentError, reason: id);
      }
    });

    test('invalid ids are rejected before any request is made', () async {
      await expectLater(host.ensureInstalled('../x'), throwsA(isA<HostError>()));
      expect(server.bundleDownloads, 0);
      expect(await host.checkForUpdate('../x'), isNull);
    });

    test('wrong token is reported, not treated as offline', () async {
      final bad = SurfacesHost(
        api: SurfacesApi(
          ServerConfig(baseUri: Uri.parse('http://127.0.0.1:8787'), token: 'nope', deviceId: 'd'),
          client: MockClient(server.handle),
        ),
        bundles: bundles,
        snapshots: SnapshotCache(Directory(tmp.path)),
      );
      await expectLater(
        bad.ensureInstalled('utilities'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'unauthorized')),
      );
      expect(bad.connectivity.value, Connectivity.unauthorized);
    });
  });

  group('malformed manifest responses', () {
    final badBodies = <String, List<int>>{
      'truncated JSON': utf8.encode('{"appId":'),
      'array': utf8.encode('[]'),
      'scalar': utf8.encode('"not an object"'),
      'null': utf8.encode('null'),
      'invalid UTF-8': [0xff],
    };
    for (final isPreview in [false, true]) {
      final mode = isPreview ? 'preview' : 'published';
      for (final entry in badBodies.entries) {
        test('$mode ${entry.key} is a controlled first-start refusal and installed fallback', () async {
          final config = isPreview ? host.api.config.forPreview() : host.api.config;
          final root = Directory('${tmp.path}/surfaces/${config.scope}');
          List<int>? malformed = entry.value;
          final client = MockClient((request) async {
            final route = isPreview ? '/previews/utilities' : '/apps/utilities';
            if (request.url.path.endsWith(route) && malformed != null) {
              return http.Response.bytes(malformed, 200);
            }
            return server.handle(request);
          });
          final checked = SurfacesHost(
            api: isPreview ? PreviewApi(config, client: client) : SurfacesApi(config, client: client),
            bundles: BundleStore(root),
            snapshots: SnapshotCache(root),
          );
          await expectLater(checked.ensureInstalled('utilities'), throwsA(isA<ManifestException>()));
          expect(await checked.checkForUpdate('utilities'), isNull);
          expect(await checked.bundles.current('utilities'), isNull);
          expect(server.bundleDownloads, 0);

          malformed = null;
          final installed = await checked.ensureInstalled('utilities');
          final pointer = File('${root.path}/apps/utilities/installed.json');
          final before = await pointer.readAsString();
          malformed = entry.value;
          final fallback = await checked.ensureInstalled('utilities');
          expect(fallback.bundleId, installed.bundleId);
          expect(fallback.preview, installed.preview);
          expect(checked.updateProblems['utilities'], isNotNull);
          expect(await checked.checkForUpdate('utilities', displayed: installed), isNull);
          expect(await pointer.readAsString(), before);
          expect(server.bundleDownloads, 1);
          expect(await checked.bundles.read(fallback, 'index.html'), isNotNull);

          malformed = null;
          expect((await checked.ensureInstalled('utilities')).bundleId, installed.bundleId);
          expect(checked.updateProblems, isEmpty, reason: 'a malformed response must not poison the queue');
        });
      }
    }
  });

  // Review finding 7: a captive portal or a failing TLS handshake is "no connection to Hermes".
  group('failures that are not an answer from the server', () {
    late String mode;
    late SurfacesHost flaky;
    final calls = [
      {
        'name': 'bills',
        'args': {'status': 'unpaid'},
      },
    ];

    setUp(() {
      mode = 'ok';
      flaky = SurfacesHost(
        api: SurfacesApi(
          host.api.config,
          client: MockClient((r) async {
            switch (mode) {
              case 'tls':
                throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
              case 'portal':
                return http.Response(
                  '<html>Sign in to the network</html>',
                  200,
                  headers: {'content-type': 'text/html'},
                );
              case 'gateway':
                return http.Response('<html>Bad gateway</html>', 502);
              default:
                return server.handle(r);
            }
          }),
        ),
        bundles: bundles,
        snapshots: SnapshotCache(bundles.root),
        clock: host.clock,
      );
    });

    for (final kind in ['tls', 'portal']) {
      test('$kind: a query is served from the stored snapshot and the host goes offline', () async {
        final app = await flaky.ensureInstalled('utilities');
        final live = await flaky.query(app, calls, timezone: 'UTC');
        expect(flaky.connectivity.value, Connectivity.online);
        mode = kind;
        final cached = await flaky.query(app, calls, timezone: 'UTC');
        expect(cached.fromCache, isTrue);
        expect(cached.reply['freshness'], 'cached');
        expect(cached.reply['results'], live.reply['results']);
        expect(flaky.connectivity.value, Connectivity.offline);
      });

      test('$kind: a query that was never fetched is "not downloaded", not an internal error', () async {
        final app = await flaky.ensureInstalled('utilities');
        mode = kind;
        await expectLater(
          flaky.query(app, calls, timezone: 'UTC'),
          throwsA(isA<HostError>().having((e) => e.code, 'code', 'offline_no_snapshot')),
        );
        expect(flaky.connectivity.value, Connectivity.offline);
      });
    }

    test('tls: an installed app still opens and an update check just reports nothing', () async {
      final installed = await flaky.ensureInstalled('utilities');
      mode = 'tls';
      server.revision = 2;
      expect((await flaky.ensureInstalled('utilities')).revision, installed.revision);
      expect(flaky.connectivity.value, Connectivity.offline);
      expect(await flaky.checkForUpdate('utilities'), isNull);
      expect(flaky.updateProblems, isEmpty, reason: 'offline is not a bad package');
    });

    test('tls: the first start explains that Hermes must be reachable', () async {
      mode = 'tls';
      await expectLater(
        flaky.ensureInstalled('utilities'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'offline_first_start')),
      );
      expect(flaky.connectivity.value, Connectivity.offline);
    });

    test('portal: a non-JSON manifest keeps the installed app running as a bad candidate', () async {
      final installed = await flaky.ensureInstalled('utilities');
      mode = 'portal';
      expect((await flaky.ensureInstalled('utilities')).bundleId, installed.bundleId);
      expect(flaky.updateProblems['utilities'], isNotNull);
    });

    test('a real server error is never answered from the cache', () async {
      final app = await flaky.ensureInstalled('utilities');
      await flaky.query(app, calls, timezone: 'UTC');
      mode = 'gateway';
      await expectLater(
        flaky.query(app, calls, timezone: 'UTC'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'server_error')),
      );
      expect(flaky.connectivity.value, Connectivity.online);
    });

    test('a rejected token is not offline either', () async {
      final app = await flaky.ensureInstalled('utilities');
      await flaky.query(app, calls, timezone: 'UTC');
      final denied = SurfacesHost(
        api: SurfacesApi(
          host.api.config,
          client: MockClient((_) async => http.Response('<html>Forbidden</html>', 403)),
        ),
        bundles: bundles,
        snapshots: SnapshotCache(bundles.root),
        clock: host.clock,
      );
      await expectLater(
        denied.query(app, calls, timezone: 'UTC'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'unauthorized')),
      );
      expect(denied.connectivity.value, Connectivity.unauthorized);
    });
  });

  group('preview lifecycle', () {
    late SurfacesHost preview;
    final gone = isA<HostError>().having((e) => e.code, 'code', 'preview_gone');

    SurfacesHost sharedHost(http.Client client, {Directory? root}) {
      final cacheRoot = root ?? Directory('${preview.bundles.root.path}/.');
      return SurfacesHost(
        api: PreviewApi(host.api.config.forPreview(), client: client),
        bundles: BundleStore(cacheRoot),
        snapshots: SnapshotCache(cacheRoot),
      );
    }

    setUp(() {
      final config = host.api.config.forPreview();
      final root = Directory('${tmp.path}/surfaces/${config.scope}');
      preview = SurfacesHost(
        api: PreviewApi(config, client: MockClient(server.handle)),
        bundles: BundleStore(root),
        snapshots: SnapshotCache(root),
      );
    });

    test('preview identity survives a fresh store and is in the same installed pointer', () async {
      final app = await preview.ensureInstalled('utilities');
      expect(app.preview, const PreviewIdentity(buildId: 'build_1', baseRevision: 0));
      final pointer = File('${preview.bundles.root.path}/apps/utilities/installed.json');
      final json = jsonDecode(await pointer.readAsString()) as Map<String, dynamic>;
      expect(json['preview'], {'buildId': 'build_1', 'baseRevision': 0});
      expect(json['bundleId'], app.bundleId);
      expect(json['revision'], app.revision);
      final restored = await BundleStore(preview.bundles.root).current('utilities');
      expect(restored!.preview, app.preview);
      expect(restored.bundleId, app.bundleId);
      expect(restored.revision, app.revision);
      expect(await preview.bundles.read(restored, 'index.html'), isNotNull);
    });

    test('legacy and corrupt optional preview metadata stays viewable but cannot authorize approval', () async {
      final app = await preview.ensureInstalled('utilities');
      final pointer = File('${preview.bundles.root.path}/apps/utilities/installed.json');
      final json = jsonDecode(await pointer.readAsString()) as Map<String, dynamic>;
      final key = await ApproverKey.fromSeed(Uint8List(32));
      final review = ReviewClient(
        SurfacesApi(
          host.api.config,
          client: MockClient((_) async {
            fail('an untrusted cached preview must not request a challenge or approve');
          }),
        ),
        key,
      );
      for (final raw in <Object?>[
        null,
        'junk',
        [],
        {},
        {'buildId': 'build_1'},
        {'baseRevision': 0},
        {'buildId': '', 'baseRevision': 0},
        {'buildId': 1, 'baseRevision': 0},
        {'buildId': 'build_1', 'baseRevision': '0'},
        {'buildId': 'build_1', 'baseRevision': 0.0},
        {'buildId': 'build_1', 'baseRevision': -1},
      ]) {
        json['preview'] = raw;
        await pointer.writeAsString(jsonEncode(json));
        final restored = await BundleStore(preview.bundles.root).current('utilities');
        expect(restored, isNotNull, reason: 'only optional metadata is damaged: $raw');
        expect(restored!.preview, isNull, reason: '$raw');
        expect(restored.bundleId, app.bundleId);
        await expectLater(review.approve(restored), throwsA(isA<ApprovalFailure>()));
      }
      json.remove('preview'); // pointers written before identity was persisted
      json['buildId'] = 'legacy_build';
      json['baseRevision'] = 0;
      await pointer.writeAsString(jsonEncode(json));
      final legacy = await BundleStore(preview.bundles.root).current('utilities');
      expect(legacy!.preview, isNull);
      expect(await preview.bundles.read(legacy, 'index.html'), isNotNull);
      await expectLater(review.approve(legacy), throwsA(isA<ApprovalFailure>()));
    });

    for (final check in [false, true]) {
      final method = check ? 'checkForUpdate' : 'ensureInstalled';
      for (final field in ['buildId', 'baseRevision']) {
        test('$method installs a $field-only change with unchanged digest and draft revision', () async {
          final first = await preview.ensureInstalled('utilities');
          final metadata = Map<String, dynamic>.from(server.previewMetadata as Map);
          metadata[field] = field == 'buildId' ? 'build_2' : 1;
          server.previewMetadata = metadata;
          final updated = check
              ? await preview.checkForUpdate('utilities')
              : await preview.ensureInstalled('utilities');
          expect(updated, isNotNull);
          expect(updated!.preview, PreviewIdentity.fromJson(metadata));
          expect(updated.preview, isNot(first.preview));
          expect(updated.revision, first.revision);
          expect(updated.bundleId, first.bundleId);
          expect(updated.dir.path, first.dir.path);
          expect(server.bundleDownloads, 2, reason: 'identity changes use the verified install path');
          final restored = await BundleStore(preview.bundles.root).current('utilities');
          expect(restored!.preview, updated.preview);
          final versions = Directory('${preview.bundles.root.path}/apps/utilities/versions');
          expect(await versions.list().length, 1, reason: 'no second copy of the same digest');
          if (check) {
            expect(await preview.checkForUpdate('utilities'), isNull);
          } else {
            expect((await preview.ensureInstalled('utilities')).preview, updated.preview);
          }
          expect(server.bundleDownloads, 2, reason: 'equal identities still take the fast path');
        });
      }

      test('$method upgrades a legacy pointer even with unchanged digest and draft revision', () async {
        final first = await preview.ensureInstalled('utilities');
        final pointer = File('${preview.bundles.root.path}/apps/utilities/installed.json');
        final json = jsonDecode(await pointer.readAsString()) as Map<String, dynamic>;
        json.remove('preview');
        await pointer.writeAsString(jsonEncode(json));
        expect((await preview.bundles.current('utilities'))!.preview, isNull);
        final updated = check ? await preview.checkForUpdate('utilities') : await preview.ensureInstalled('utilities');
        expect(updated!.preview, first.preview);
        expect(server.bundleDownloads, 2);
        expect((await BundleStore(preview.bundles.root).current('utilities'))!.preview, first.preview);
      });
    }

    test('an aborted identity-only install preserves the exact previous pointer', () async {
      final first = await preview.ensureInstalled('utilities');
      final pointer = File('${preview.bundles.root.path}/apps/utilities/installed.json');
      final before = await pointer.readAsString();
      final bundle = verifyBundle(Uint8List.fromList(zipOf('good')), expectedId: first.bundleId);
      await expectLater(
        preview.bundles.install(
          'utilities',
          bundle,
          title: first.title,
          revision: first.revision,
          contractHash: first.contractHash,
          epoch: first.epoch,
          preview: const PreviewIdentity(buildId: 'build_2', baseRevision: 1),
          onBeforeSwitch: () async => throw StateError('form not flushed'),
        ),
        throwsStateError,
      );
      expect(await pointer.readAsString(), before);
      final restored = await BundleStore(preview.bundles.root).current('utilities');
      expect(restored!.preview, first.preview);
      expect(await preview.bundles.read(restored, 'index.html'), isNotNull);
      expect(Directory('${preview.bundles.root.path}/apps/utilities/staging').existsSync(), isFalse);
    });

    test('a preview manifest missing metadata is refused before download', () async {
      server.includePreviewMetadata = false;
      await expectLater(preview.ensureInstalled('utilities'), throwsA(isA<ManifestException>()));
      expect(server.bundleDownloads, 0);
      expect(await preview.bundles.current('utilities'), isNull);
    });

    test('malformed preview metadata cannot replace an installed identity on either path', () async {
      final first = await preview.ensureInstalled('utilities');
      server.previewMetadata = {'buildId': 'build_2', 'baseRevision': '0'};
      final opened = await preview.ensureInstalled('utilities');
      expect(opened.preview, first.preview);
      expect(preview.updateProblems['utilities'], isNotNull);
      expect(await preview.checkForUpdate('utilities'), isNull);
      expect((await preview.bundles.current('utilities'))!.preview, first.preview);
      expect(server.bundleDownloads, 1);
    });

    test('a decided preview cannot reopen its cached bundle', () async {
      await preview.ensureInstalled('utilities');
      server.previewGone = true;
      await expectLater(preview.ensureInstalled('utilities'), throwsA(gone));
      expect(await preview.bundles.current('utilities'), isNotNull);
      expect(preview.connectivity.value, Connectivity.online);
    });

    test('a missing preview on first start reports that review ended', () async {
      server.previewGone = true;
      await expectLater(preview.ensureInstalled('utilities'), throwsA(gone));
    });

    test('an update check reports a decided preview, not unchanged content', () async {
      await preview.ensureInstalled('utilities');
      server.previewGone = true;
      await expectLater(preview.checkForUpdate('utilities'), throwsA(gone));
    });

    test('a query after publication reports that review ended', () async {
      final app = await preview.ensureInstalled('utilities');
      server.previewGone = true;
      await expectLater(preview.query(app, [], timezone: 'UTC'), throwsA(gone));
    });

    test('offline is not evidence that review ended: cached preview still opens', () async {
      final app = await preview.ensureInstalled('utilities');
      server.online = false;
      expect((await preview.ensureInstalled('utilities')).bundleId, app.bundleId);
      expect(preview.connectivity.value, Connectivity.offline);
    });

    test('displayed preview catches up to a version another host already installed without downloading', () async {
      final displayed = await preview.ensureInstalled('utilities');
      server.previewMetadata = {'buildId': 'build_2', 'baseRevision': 1};
      final background = sharedHost(MockClient(server.handle));
      final latest = (await background.checkForUpdate('utilities'))!;
      expect(latest.bundleId, displayed.bundleId);
      expect(latest.revision, displayed.revision);
      expect(latest.preview, isNot(displayed.preview));
      final downloads = server.bundleDownloads;

      expect(await preview.checkForUpdate('utilities'), isNull, reason: 'omitted displayed keeps old behavior');
      final catchUp = (await preview.checkForUpdate('utilities', displayed: displayed))!;
      expect(catchUp.preview, latest.preview);
      expect(catchUp.bundleId, latest.bundleId);
      expect(await preview.checkForUpdate('utilities', displayed: catchUp), isNull);
      expect(server.bundleDownloads, downloads);
      server.previewGone = true;
      await expectLater(preview.checkForUpdate('utilities', displayed: displayed), throwsA(gone));
    });

    test('displayed catch-up compares all identity fields, not object instance or install timestamp', () async {
      final latest = await preview.ensureInstalled('utilities');
      for (final field in ['appId', 'bundleId', 'revision', 'contractHash', 'epoch', 'preview', 'cosmetic']) {
        final displayed = InstalledApp(
          appId: field == 'appId' ? 'other' : latest.appId,
          title: 'another title',
          bundleId: field == 'bundleId' ? idOf('wrong_bundle_id') : latest.bundleId,
          revision: field == 'revision' ? latest.revision + 1 : latest.revision,
          contractHash: field == 'contractHash' ? 'sha256:other' : latest.contractHash,
          epoch: field == 'epoch' ? 'other_epoch' : latest.epoch,
          preview: field == 'preview' ? null : latest.preview,
          dir: latest.dir,
          files: latest.files,
          entrypoint: latest.entrypoint,
          installedAt: latest.installedAt.subtract(const Duration(days: 1)),
        );
        final checked = await preview.checkForUpdate('utilities', displayed: displayed);
        if (field == 'cosmetic') {
          expect(checked, isNull);
        } else {
          expect(checked, isNotNull, reason: field);
          expect(checked!.preview, latest.preview, reason: field);
          expect(checked.bundleId, latest.bundleId, reason: field);
        }
      }
      final reopened = (await BundleStore(preview.bundles.root).current('utilities'))!;
      expect(await preview.checkForUpdate('utilities', displayed: reopened), isNull);
      expect(server.bundleDownloads, 1);
    });

    test('a displayed check queued behind another update returns its already-installed target', () async {
      final displayed = await preview.ensureInstalled('utilities');
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var paused = false;
      final background = sharedHost(
        MockClient((request) async {
          final response = await server.handle(request);
          if (request.url.path.contains('/previews/utilities/bundles/') && !paused) {
            paused = true;
            entered.complete();
            await release.future;
          }
          return response;
        }),
      );
      server.previewMetadata = {'buildId': 'build_2', 'baseRevision': 1};
      final update = background.checkForUpdate('utilities');
      await entered.future;
      final catchUp = preview.checkForUpdate('utilities', displayed: displayed);
      await preview.ensureInstalled('other'); // independent-app event barrier
      expect((await preview.bundles.current('utilities'))!.preview, displayed.preview);
      release.complete();
      final installed = (await update)!;
      expect((await catchUp)!.preview, installed.preview);
      expect(server.bundleDownloads, 3, reason: 'baseline, updating app and other app only; no catch-up download');
    });

    for (final pauseAt in ['manifest', 'bundle']) {
      for (final firstChecks in [false, true]) {
        test(
          'cross-host ${firstChecks ? 'check/ensure' : 'ensure/check'} queues $pauseAt fetch through metadata install',
          () async {
            final initial = await preview.ensureInstalled('utilities');
            final entered = Completer<void>();
            final release = Completer<void>();
            addTearDown(() {
              if (!release.isCompleted) release.complete();
            });
            var paused = false;
            var manifests = 0;
            final client = MockClient((request) async {
              final path = request.url.path;
              if (path.endsWith('/previews/utilities')) manifests++;
              // Capture the old identity before suspending the response.
              final response = await server.handle(request);
              final isTarget = pauseAt == 'manifest'
                  ? path.endsWith('/previews/utilities')
                  : path.contains('/previews/utilities/bundles/');
              if (isTarget && !paused) {
                paused = true;
                entered.complete();
                await release.future;
              }
              return response;
            });
            final firstHost = sharedHost(client);
            final secondHost = sharedHost(client);
            server.previewMetadata = {'buildId': 'build_2', 'baseRevision': 1};
            final first = firstChecks ? firstHost.checkForUpdate('utilities') : firstHost.ensureInstalled('utilities');
            await entered.future;
            server.previewMetadata = {'buildId': 'build_3', 'baseRevision': 2};
            final second = firstChecks
                ? secondHost.ensureInstalled('utilities')
                : secondHost.checkForUpdate('utilities');

            // Independent app completion is an event barrier, not a timing-based sleep.
            expect((await secondHost.ensureInstalled('other')).appId, 'other');
            expect(manifests, 1, reason: 'a newer request cannot overtake a paused manifest/install');
            expect((await preview.bundles.current('utilities'))!.preview, initial.preview);
            release.complete();
            final oldCandidate = await first;
            expect(oldCandidate!.preview, const PreviewIdentity(buildId: 'build_2', baseRevision: 1));
            final newest = await second;
            expect(newest!.preview, const PreviewIdentity(buildId: 'build_3', baseRevision: 2));
            expect(newest.bundleId, initial.bundleId);
            expect(newest.revision, initial.revision);
            expect((await BundleStore(preview.bundles.root).current('utilities'))!.preview, newest.preview);
            expect(manifests, 2);
            expect(await Directory('${preview.bundles.root.path}/apps/utilities/versions').list().length, 1);
          },
        );
      }
    }

    for (final failureKind in ['unexpected', 'bad_metadata', 'preview_gone']) {
      test('a queued refresh proceeds after $failureKind without stale pointer/identity', () async {
        final initial = await preview.ensureInstalled('utilities');
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        var firstRequest = true;
        var manifests = 0;
        final client = MockClient((request) async {
          if (request.url.path.endsWith('/previews/utilities')) {
            manifests++;
            if (firstRequest) {
              firstRequest = false;
              entered.complete();
              await release.future;
              if (failureKind == 'unexpected') throw StateError('request failed');
              if (failureKind == 'preview_gone') return http.Response('{"error":"decided"}', 404);
              final response = await server.handle(request);
              final json = jsonDecode(response.body) as Map<String, dynamic>;
              json['preview'] = {'buildId': 'build_bad', 'baseRevision': '0'};
              return http.Response(jsonEncode(json), 200, headers: {'content-type': 'application/json; charset=utf-8'});
            }
          }
          return server.handle(request);
        });
        final firstHost = sharedHost(client);
        final secondHost = sharedHost(client);
        final first = firstHost.checkForUpdate('utilities');
        final failure = failureKind == 'unexpected'
            ? expectLater(first, throwsStateError)
            : failureKind == 'preview_gone'
            ? expectLater(first, throwsA(gone))
            : null;
        await entered.future;
        server.previewMetadata = {'buildId': 'build_2', 'baseRevision': 1};
        final second = secondHost.ensureInstalled('utilities');
        await secondHost.ensureInstalled('other');
        expect(manifests, 1);
        expect((await preview.bundles.current('utilities'))!.preview, initial.preview);
        release.complete();
        if (failure != null) {
          await failure;
        } else {
          expect(await first, isNull);
          expect(firstHost.updateProblems['utilities'], isNotNull);
        }
        final updated = await second;
        expect(updated.preview, const PreviewIdentity(buildId: 'build_2', baseRevision: 1));
        expect((await preview.bundles.current('utilities'))!.preview, updated.preview);
        expect(
          (await secondHost.ensureInstalled('utilities')).preview,
          updated.preview,
          reason: 'the queue remains usable after it drains',
        );
      });
    }

    test('a queued offline ensure reads the pointer after the preceding update completes', () async {
      final initial = await preview.ensureInstalled('utilities');
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var paused = false;
      final updating = sharedHost(
        MockClient((request) async {
          final response = await server.handle(request);
          if (request.url.path.contains('/previews/utilities/bundles/') && !paused) {
            paused = true;
            entered.complete();
            await release.future;
          }
          return response;
        }),
      );
      final offline = sharedHost(
        MockClient((request) async {
          if (request.url.path.endsWith('/previews/utilities')) {
            throw const SocketException('offline');
          }
          return server.handle(request);
        }),
      );
      server.previewMetadata = {'buildId': 'build_2', 'baseRevision': 1};
      final update = updating.checkForUpdate('utilities');
      await entered.future;
      final fallback = offline.ensureInstalled('utilities');
      await offline.ensureInstalled('other');
      release.complete();
      final installed = (await update)!;
      final cached = await fallback;
      expect(installed.preview, isNot(initial.preview));
      expect(cached.preview, installed.preview);
      expect(offline.connectivity.value, Connectivity.offline);
    });

    test('same app in a different cache root can refresh while another host is paused', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final blocked = sharedHost(
        MockClient((request) async {
          final response = await server.handle(request);
          if (request.url.path.endsWith('/previews/utilities')) {
            entered.complete();
            await release.future;
          }
          return response;
        }),
      );
      final first = blocked.ensureInstalled('utilities');
      await entered.future;
      server.previewMetadata = {'buildId': 'build_2', 'baseRevision': 1};
      final independent = sharedHost(MockClient(server.handle), root: Directory('${tmp.path}/independent'));
      expect(
        (await independent.ensureInstalled('utilities')).preview,
        const PreviewIdentity(buildId: 'build_2', baseRevision: 1),
      );
      expect(await blocked.bundles.current('utilities'), isNull);
      release.complete();
      expect((await first).preview, const PreviewIdentity(buildId: 'build_1', baseRevision: 0));
    });
  });

  group('queries and snapshots', () {
    final calls = [
      {
        'name': 'bills',
        'args': {'status': 'unpaid'},
      },
    ];

    test('live answer is stored and an identical request offline is served from it', () async {
      final app = await host.ensureInstalled('utilities');
      final live = await host.query(app, calls, timezone: 'Europe/Moscow');
      expect(live.reply['freshness'], 'live');
      expect(live.reply['dataRev'], 10);

      server.online = false;
      final cached = await host.query(app, calls, timezone: 'Europe/Moscow');
      expect(cached.fromCache, isTrue);
      expect(cached.reply['freshness'], 'cached');
      expect(cached.reply['results'], live.reply['results']);
      expect(cached.reply['fetchedAt'], live.reply['fetchedAt']);
    });

    test('a filter that was never fetched is "not downloaded", never an empty list', () async {
      final app = await host.ensureInstalled('utilities');
      await host.query(app, calls, timezone: 'Europe/Moscow');
      server.online = false;
      await expectLater(
        host.query(app, [
          {
            'name': 'bills',
            'args': {'status': 'paid'},
          },
        ], timezone: 'Europe/Moscow'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'offline_no_snapshot')),
      );
    });

    test('a different time zone does not reuse the snapshot', () async {
      final app = await host.ensureInstalled('utilities');
      await host.query(app, calls, timezone: 'Europe/Moscow');
      server.online = false;
      await expectLater(host.query(app, calls, timezone: 'Asia/Tokyo'), throwsA(isA<HostError>()));
    });

    test('snapshots of another contract are not shown to a new package', () async {
      final app = await host.ensureInstalled('utilities');
      await host.query(app, calls, timezone: 'UTC');
      final changed = InstalledApp(
        appId: app.appId,
        title: app.title,
        bundleId: app.bundleId,
        revision: app.revision,
        contractHash: 'sha256:OTHER',
        epoch: app.epoch,
        dir: app.dir,
        files: app.files,
        entrypoint: app.entrypoint,
        installedAt: app.installedAt,
      );
      server.online = false;
      await expectLater(host.query(changed, calls, timezone: 'UTC'), throwsA(isA<HostError>()));
    });

    test('the host, not the page, supplies the revision', () async {
      final app = await host.ensureInstalled('utilities');
      await host.query(app, calls, timezone: 'UTC');
      expect(server.dataRequests.single['revision'], app.revision);
    });

    test('stale revision is reported as such', () async {
      final app = await host.ensureInstalled('utilities');
      server.status = 409;
      await expectLater(
        host.query(app, calls, timezone: 'UTC'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'stale_revision')),
      );
    });

    // Review finding 4: the cache write is best effort; the live answer is what the page asked for.
    test('a snapshot that cannot be written does not discard the live answer (real disk failure)', () async {
      final app = await host.ensureInstalled('utilities');
      // A file where the snapshots directory must go makes every write fail with a FileSystemException.
      File('${bundles.root.path}/apps/utilities/snapshots').writeAsStringSync('in the way');
      final live = await host.query(app, calls, timezone: 'Europe/Moscow');
      expect(live.fromCache, isFalse);
      expect(live.reply['freshness'], 'live');
      expect(live.reply['dataRev'], 10);
      expect((live.reply['results'] as Map)['bills'], isNotNull);
      expect(host.connectivity.value, Connectivity.online);

      // Nothing was stored, so offline is the honest "not downloaded", never a fabricated answer.
      server.online = false;
      await expectLater(
        host.query(app, calls, timezone: 'Europe/Moscow'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'offline_no_snapshot')),
      );
    });

    test('a full disk on the snapshot store still returns the live answer', () async {
      final full = _FullDiskSnapshots(bundles.root);
      final failing = SurfacesHost(api: host.api, bundles: bundles, snapshots: full, clock: host.clock);
      final app = await failing.ensureInstalled('utilities');
      final live = await failing.query(app, calls, timezone: 'UTC');
      expect(full.attempts, 1);
      expect(live.reply['freshness'], 'live');
      expect(live.reply['dataRev'], 10);
      expect(failing.connectivity.value, Connectivity.online);
    });

    test('identical queries running together all return live answers and leave one usable snapshot', () async {
      // A reload or hermes:data-changed during the first query starts the same group twice.
      final app = await host.ensureInstalled('utilities');
      final outcomes = await Future.wait([for (var i = 0; i < 6; i++) host.query(app, calls, timezone: 'UTC')]);
      expect(outcomes.map((o) => o.reply['freshness']), everyElement('live'));
      server.online = false;
      final cached = await host.query(app, calls, timezone: 'UTC');
      expect(cached.fromCache, isTrue);
      expect(cached.reply['results'], outcomes.first.reply['results']);
    });

    test('a server error is still an error when the cache is broken too', () async {
      final full = _FullDiskSnapshots(bundles.root);
      final failing = SurfacesHost(api: host.api, bundles: bundles, snapshots: full, clock: host.clock);
      final app = await failing.ensureInstalled('utilities');
      server.status = 409;
      await expectLater(
        failing.query(app, calls, timezone: 'UTC'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', 'stale_revision')),
      );
      expect(full.attempts, 0, reason: 'nothing to store when the server refused');
    });

    test('clearing snapshots removes cached data but keeps the installed app', () async {
      final app = await host.ensureInstalled('utilities');
      await host.query(app, calls, timezone: 'UTC');
      await host.snapshots.clearAll();
      server.online = false;
      await expectLater(host.query(app, calls, timezone: 'UTC'), throwsA(isA<HostError>()));
      expect(await bundles.current('utilities'), isNotNull);
    });
  });
}
