import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Produced by plugin/mobile_surfaces_core/approval.py with the same fixed seed (cryptography 49):
// the server and the phone must agree byte for byte on key derivation, message and signature.
const seedB64 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
const publicB64 = 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=';
const signatureB64 =
    'K2Cx6p3VjcOHbHRRh6XaON+peqgB7uRGyZwfS4VKAKYhjcN1e3ONWshRt240QiMn0J5hZZepxGpr3dG/BE1ZCA==';
final bundleA = 'sha256:${'a' * 64}';

/// A response body as the real server sends it: UTF-8 bytes (the default String body is Latin-1).
http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

String message({String build = 'build_1', int rev = 7, String? bundle, int base = 3, String nonce = 'n0nce'}) =>
    canonicalApprovalMessage(
        appId: 'zhkh', buildId: build, draftRev: rev, bundleId: bundle ?? bundleA, baseRevision: base, nonce: nonce);

ServerConfig config() =>
    ServerConfig(baseUri: Uri.parse('http://127.0.0.1:18787'), token: 'secret-token', deviceId: 'dev1');

void main() {
  group('signature compatibility with the server', () {
    test('the same seed gives the same public key and the same signature as Python', () async {
      final key = await ApproverKey.fromSeed(Uint8List.fromList(base64Decode(seedB64)));
      expect(key.publicKeyBase64, publicB64);
      expect(await key.sign(message()), signatureB64);
    });

    test('the signed text is the documented fixed layout', () {
      expect(message().split('\n'), [
        'ms-approve-v1',
        'app:zhkh',
        'build:build_1',
        'draftRev:7',
        'bundle:$bundleA',
        'base:3',
        'nonce:n0nce',
      ]);
      expect(message().endsWith('\n'), isFalse);
    });

    test('a different build, revision, bundle, base or nonce changes the signature', () async {
      final key = await ApproverKey.fromSeed(Uint8List.fromList(base64Decode(seedB64)));
      final base = await key.sign(message());
      expect(await key.sign(message(build: 'build_2')), isNot(base));
      expect(await key.sign(message(rev: 8)), isNot(base));
      expect(await key.sign(message(bundle: 'sha256:${'b' * 64}')), isNot(base));
      expect(await key.sign(message(base: 4)), isNot(base));
      expect(await key.sign(message(nonce: 'other')), isNot(base));
    });

    test('the key is created once and loaded again unchanged', () async {
      final dir = await Directory.systemTemp.createTemp('approver_key');
      addTearDown(() => dir.delete(recursive: true));
      final first = await ApproverKey.loadOrCreate(dir);
      final second = await ApproverKey.loadOrCreate(dir);
      expect(second.publicKeyBase64, first.publicKeyBase64);
      expect(base64Decode(first.publicKeyBase64).length, 32);
      expect((await File('${dir.path}/approver_ed25519.key').readAsString()).isNotEmpty, isTrue);
    });
  });

  group('loading an existing approver without replacement', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('existing_approver');
    });
    tearDown(() => dir.delete(recursive: true));

    test('missing identity returns null without writing a key or creating a directory', () async {
      expect(await ApproverKey.loadExisting(dir), isNull);
      expect(await dir.list().toList(), isEmpty);
      final missing = Directory('${dir.path}/not_created');
      expect(await ApproverKey.loadExisting(missing), isNull);
      expect(await missing.exists(), isFalse);
    });

    test('loads the persisted synthetic seed unchanged with the compatible signature', () async {
      final file = File('${dir.path}/approver_ed25519.key');
      final content = ' $seedB64\n';
      await file.writeAsString(content, flush: true);
      final key = await ApproverKey.loadExisting(dir);
      expect(key, isNotNull);
      expect(key!.publicKeyBase64, publicB64);
      expect(await key.sign(message()), signatureB64);
      expect(await file.readAsString(), content);
      expect(await dir.list().toList(), hasLength(1));
    });

    for (final content in ['', 'synthetic-secret:invalid-base64', base64Encode(List<int>.filled(31, 7)),
      base64Encode(List<int>.filled(33, 7))]) {
      test('corrupt identity is not replaced and errors do not expose its contents (${content.length})', () async {
        final file = File('${dir.path}/approver_ed25519.key');
        await file.writeAsString(content, flush: true);
        // The failure carries a stable key (localized by the UI) and a fixed English diagnostic that never
        // quotes the file; the Russian wording is asserted through the string layer.
        await expectLater(ApproverKey.loadExisting(dir), throwsA(isA<ApprovalFailure>()
            .having((e) => e.key, 'key', SurfacesText.approvalKeyCorrupt)
            .having((e) => e.message, 'sanitized error',
                'The saved approval key is damaged. Pairing was not redone.')));
        expect(SurfacesStrings.forLanguage('ru')(SurfacesText.approvalKeyCorrupt),
            'Сохранённый ключ подтверждения повреждён. Перепривязка не выполнялась.');
        expect(await file.readAsString(), content);
        expect(await dir.list().toList(), hasLength(1));
      });
    }
  });

  group('approving', () {
    late ApproverKey key;
    setUp(() async => key = await ApproverKey.fromSeed(Uint8List.fromList(base64Decode(seedB64))));

    InstalledApp shown({String build = 'build_1', int rev = 7, String? bundle, int base = 3, bool hasPreview = true}) =>
        InstalledApp(
          appId: 'zhkh', title: 'ЖКХ', bundleId: bundle ?? bundleA, revision: rev,
          contractHash: 'sha256:contract', epoch: 'e1', dir: Directory.systemTemp, files: {'index.html'},
          entrypoint: 'index.html', installedAt: DateTime.utc(2026, 10, 11),
          preview: hasPreview ? PreviewIdentity(buildId: build, baseRevision: base) : null,
        );

    ReviewClient client(Map<String, dynamic> Function() challenge, List<http.Request> seen,
        {int approveStatus = 200}) {
      final mock = MockClient((req) async {
        seen.add(req);
        if (req.url.path.endsWith('/challenge')) return http.Response(jsonEncode(challenge()), 200);
        if (req.url.path.endsWith('/approve')) {
          return http.Response(jsonEncode(approveStatus == 200 ? {'status': 'published', 'revision': 5} : {'error': 'no'}),
              approveStatus);
        }
        return http.Response('{}', 404);
      });
      return ReviewClient(SurfacesApi(config(), client: mock), key);
    }

    Map<String, dynamic> honest({String build = 'build_1', int rev = 7, String? bundle, int base = 3, String nonce = 'n0nce'}) => {
          'appId': 'zhkh',
          'buildId': build,
          'draftRev': rev,
          'bundleId': bundle ?? bundleA,
          'baseRevision': base,
          'nonce': nonce,
          'message': message(build: build, rev: rev, bundle: bundle, base: base, nonce: nonce),
        };

    test('signs what the server asked for and posts the signature with the build', () async {
      final seen = <http.Request>[];
      final revision = await client(() => honest(), seen).approve(shown());

      expect(revision, 5);
      final approve = seen.last;
      expect(approve.url.path, endsWith('/previews/zhkh/approve'));
      final body = jsonDecode(approve.body) as Map<String, dynamic>;
      expect(body['buildId'], 'build_1');
      expect(body['nonce'], 'n0nce');
      expect(body['signature'], signatureB64);
      expect(approve.headers['Authorization'], 'Bearer secret-token');
    });

    test('approval uses the newer installed identity, not an older preview listing', () async {
      final listing = PreviewSummary(
          appId: 'zhkh', title: 'ЖКХ', draftRev: 7, buildId: 'build_1', baseRevision: 3, isNew: false);
      final newerBundle = 'sha256:${'b' * 64}';
      final installed = shown(build: 'build_2', rev: 8, bundle: newerBundle, base: 4);
      expect(installed.preview!.buildId, isNot(listing.buildId));
      final seen = <http.Request>[];
      final c = client(() => honest(build: 'build_2', rev: 8, bundle: newerBundle, base: 4, nonce: 'new_nonce'), seen);
      expect(await c.approve(installed), 5);
      final posted = jsonDecode(seen.last.body) as Map<String, dynamic>;
      expect(posted['buildId'], installed.preview!.buildId);
      expect(posted['nonce'], 'new_nonce');
      expect(posted['signature'], await key.sign(message(build: 'build_2', rev: 8, bundle: newerBundle, base: 4, nonce: 'new_nonce')));
      expect(seen.map((r) => r.url.path), [
        '$apiPrefix/previews/zhkh/challenge', '$apiPrefix/previews/zhkh/approve',
      ]);
    });

    test('missing installed identity fails before challenge or signing', () async {
      final seen = <http.Request>[];
      final c = client(() => honest(), seen);
      await expectLater(c.approve(shown(hasPreview: false)), throwsA(isA<ApprovalFailure>()));
      expect(seen, isEmpty);
    });

    test('refuses a changed draft revision', () async {
      final seen = <http.Request>[];
      final c = client(() => honest(rev: 8), seen);
      await expectLater(c.approve(shown()), throwsA(isA<ApprovalFailure>()));
      expect(seen.where((r) => r.url.path.endsWith('/approve')), isEmpty);
    });

    test('refuses a changed base revision', () async {
      final seen = <http.Request>[];
      final c = client(() => honest(base: 4), seen);
      await expectLater(c.approve(shown()), throwsA(isA<ApprovalFailure>()));
      expect(seen.where((r) => r.url.path.endsWith('/approve')), isEmpty);
    });

    for (final entry in <String, Object>{
      'appId': 'other_app', 'buildId': 'build_2', 'draftRev': 8,
      'bundleId': 'sha256:${'b' * 64}', 'baseRevision': 4, 'nonce': 'other_nonce',
    }.entries) {
      test('refuses mismatching ${entry.key} even when the message matches the installed preview', () async {
        final seen = <http.Request>[];
        final tampered = honest()..[entry.key] = entry.value;
        final c = client(() => tampered, seen);
        await expectLater(c.approve(shown()), throwsA(isA<ApprovalFailure>()));
        expect(seen.where((r) => r.url.path.endsWith('/approve')), isEmpty);
      });
    }

    test('missing or wrong-typed challenge fields never authorize approval', () async {
      for (final field in ['appId', 'buildId', 'draftRev', 'bundleId', 'baseRevision', 'nonce', 'message']) {
        for (final value in <Object?>[null, field == 'draftRev' || field == 'baseRevision' ? '3' : 3]) {
          final seen = <http.Request>[];
          final tampered = honest()..[field] = value;
          final c = client(() => tampered, seen);
          await expectLater(c.approve(shown()), throwsA(isA<ApprovalFailure>()), reason: '$field: $value');
          expect(seen.where((r) => r.url.path.endsWith('/approve')), isEmpty);
        }
      }
    });

    test('refuses to sign when the server names a different build than the one on screen', () async {
      final seen = <http.Request>[];
      final c = client(() => honest(build: 'build_2'), seen);
      await expectLater(c.approve(shown()), throwsA(isA<ApprovalFailure>()));
      expect(seen.where((r) => r.url.path.endsWith('/approve')), isEmpty, reason: 'nothing was signed or sent');
    });

    test('refuses to sign when the bundle differs from the one the user previewed', () async {
      final seen = <http.Request>[];
      final other = 'sha256:${'b' * 64}';
      final c = client(() => honest(bundle: other), seen);
      await expectLater(c.approve(shown()), throwsA(isA<ApprovalFailure>()));
      expect(seen.where((r) => r.url.path.endsWith('/approve')), isEmpty);
    });

    test('refuses a server message that does not match its own fields', () async {
      final seen = <http.Request>[];
      final tampered = honest()..['message'] = message(rev: 99);
      final c = client(() => tampered, seen);
      await expectLater(c.approve(shown()), throwsA(isA<ApprovalFailure>()));
      expect(seen.where((r) => r.url.path.endsWith('/approve')), isEmpty);
    });

    test('a damaged challenge is a failure, not a crash', () async {
      final seen = <http.Request>[];
      final c = client(() => {'nonce': 5}, seen);
      await expectLater(c.approve(shown()), throwsA(isA<ApprovalFailure>()));
    });

    test('an unsigned-by-us refusal from the server surfaces as the API error', () async {
      final seen = <http.Request>[];
      final c = client(() => honest(), seen, approveStatus: 422);
      await expectLater(c.approve(shown()),
          throwsA(isA<ApiException>().having((e) => e.status, 'status', 422)));
    });
  });

  group('rejecting', () {
    late ApproverKey key;
    setUp(() async => key = await ApproverKey.fromSeed(Uint8List.fromList(base64Decode(seedB64))));
    InstalledApp shown({bool hasPreview = true}) => InstalledApp(
      appId: 'zhkh', title: 'ЖКХ', bundleId: bundleA, revision: 8,
      contractHash: 'contract', epoch: 'e1', dir: Directory.systemTemp, files: {'index.html'},
      entrypoint: 'index.html', installedAt: DateTime.utc(2026, 10, 14),
      preview: hasPreview ? const PreviewIdentity(buildId: 'build_bbbbbbbbbb', baseRevision: 3) : null,
    );

    test('posts the displayed build identity without a challenge or signature', () async {
      final seen = <http.Request>[];
      final api = SurfacesApi(config(), client: MockClient((r) async {
        seen.add(r);
        return jsonResponse({'status': 'rejected'});
      }));
      await ReviewClient(api, key).reject(shown());
      expect(seen, hasLength(1));
      expect(seen.single.url.path, endsWith('/previews/zhkh/reject'));
      expect(seen.single.method, 'POST');
      expect(seen.single.headers['Content-Type'], 'application/json');
      expect(jsonDecode(seen.single.body), {'buildId': 'build_bbbbbbbbbb'});
    });

    test('missing installed build metadata refuses rejection before making a request', () async {
      final seen = <http.Request>[];
      final api = SurfacesApi(config(), client: MockClient((r) async {
        seen.add(r);
        return jsonResponse({'status': 'rejected'});
      }));
      await expectLater(ReviewClient(api, key).reject(shown(hasPreview: false)), throwsA(isA<ApprovalFailure>()));
      expect(seen, isEmpty);
    });

    for (final status in [401, 409, 500]) {
      test('server rejection failure $status is not swallowed', () async {
        final api = SurfacesApi(config(), client: MockClient((_) async => jsonResponse({'error': 'not rejected'}, status)));
        await expectLater(ReviewClient(api, key).reject(shown()),
            throwsA(isA<ApiException>().having((e) => e.status, 'status', status)));
      });
    }
  });

  group('pairing and listing', () {
    late ApproverKey key;
    setUp(() async => key = await ApproverKey.fromSeed(Uint8List.fromList(base64Decode(seedB64))));

    test('pair posts the public key and reports a server that already has another approver', () async {
      var status = 200;
      http.Request? sent;
      final c = ReviewClient(
          SurfacesApi(config(), client: MockClient((r) async {
            sent = r;
            return http.Response(jsonEncode(status == 200 ? {'paired': true} : {'error': 'taken'}), status);
          })),
          key);
      expect(await c.pair(), isTrue);
      expect(jsonDecode(sent!.body), {'deviceId': 'dev1', 'publicKey': publicB64});
      status = 409;
      expect(await c.pair(), isFalse);
    });

    test('malformed preview entries are dropped, not trusted', () async {
      final c = ReviewClient(
          SurfacesApi(config(), client: MockClient((r) async => jsonResponse({
                'previews': [
                  {'appId': 'zhkh', 'title': 'ЖКХ', 'draftRev': 2, 'buildId': 'b', 'baseRevision': 1, 'isNew': false},
                  {'appId': '../etc', 'title': 'x', 'draftRev': 1, 'buildId': 'b', 'baseRevision': 0, 'isNew': true},
                  {'appId': 'ok_app', 'title': 5, 'draftRev': 1},
                  'junk',
                ]
              }))),
          key);
      final list = await c.previews();
      expect(list.map((p) => p.appId), ['zhkh']);
    });
  });

  group('preview identity and manifest validation', () {
    Map<String, dynamic> manifest() => {
      'appId': 'zhkh', 'title': 'ЖКХ', 'revision': 7, 'epoch': 'e1',
      'bundle': {'bundleId': bundleA, 'size': 3, 'format': 1, 'sdkMajor': 1, 'capabilities': <String>[]},
    };
    final malformed = <Object?>[
      null, 'junk', [], {}, {'buildId': 'build_1'}, {'baseRevision': 3},
      {'buildId': 1, 'baseRevision': 3}, {'buildId': '', 'baseRevision': 3},
      {'buildId': '   ', 'baseRevision': 3}, {'buildId': 'build_1', 'baseRevision': '3'},
      {'buildId': 'build_1', 'baseRevision': 3.0}, {'buildId': 'build_1', 'baseRevision': -1},
    ];

    test('identity is immutable value metadata and round trips through JSON', () {
      const first = PreviewIdentity(buildId: 'build_1', baseRevision: 3);
      final restored = PreviewIdentity.fromJson(jsonDecode(jsonEncode(first.toJson())));
      expect(first.toJson(), {'buildId': 'build_1', 'baseRevision': 3});
      expect(restored, first);
      expect(restored.hashCode, first.hashCode);
      expect({first, restored}, hasLength(1));
      expect(const PreviewIdentity(buildId: 'build_2', baseRevision: 3), isNot(first));
      expect(const PreviewIdentity(buildId: 'build_1', baseRevision: 4), isNot(first));
      expect(first == Object(), isFalse);
    });

    test('published manifests may omit preview metadata', () {
      expect(AppManifest.parse(manifest(), expectedAppId: 'zhkh').preview, isNull);
    });

    test('PreviewApi rejects missing preview metadata', () async {
      final api = PreviewApi(config().forPreview(), client: MockClient((_) async => jsonResponse(manifest())));
      await expectLater(api.manifest('zhkh'), throwsA(isA<ManifestException>()));
    });

    test('present but malformed preview metadata is refused on published manifests', () {
      for (final raw in malformed) {
        expect(() => PreviewIdentity.fromJson(raw), throwsFormatException, reason: '$raw');
        expect(() => AppManifest.parse(manifest()..['preview'] = raw, expectedAppId: 'zhkh'),
            throwsA(isA<ManifestException>()), reason: '$raw');
      }
    });

    test('PreviewApi also refuses every malformed preview identity', () async {
      for (final raw in malformed) {
        final api = PreviewApi(config().forPreview(), client: MockClient((_) async => jsonResponse(manifest()..['preview'] = raw)));
        await expectLater(api.manifest('zhkh'), throwsA(isA<ManifestException>()), reason: '$raw');
      }
    });
  });

  group('preview routing', () {
    test('a preview uses its own scope, so it cannot share installs or origin with the published app', () {
      final published = config();
      final preview = published.forPreview();
      expect(preview.scope, isNot(published.scope));
      expect(AppOrigin.forApp(preview.scope, 'zhkh').origin, isNot(AppOrigin.forApp(published.scope, 'zhkh').origin));
      expect(preview.token, published.token);
    });

    test('PreviewApi asks the preview routes for manifest, bundle and data', () async {
      final paths = <String>[];
      final api = PreviewApi(config().forPreview(), client: MockClient((req) async {
        paths.add('${req.method} ${req.url.path}');
        if (req.url.path == '/api/plugins/mobile-surfaces/v1/previews/zhkh') {
          return jsonResponse({
            'appId': 'zhkh',
            'title': 'ЖКХ',
            'revision': 4,
            'epoch': 'e1',
            'preview': {'buildId': 'build_1', 'baseRevision': 3, 'isNew': false, 'submittedAt': '2026-10-11T09:30:00Z'},
            'bundle': {
              'bundleId': bundleA,
              'size': 3,
              'format': 1,
              'sdkMajor': 1,
              'capabilities': <String>[],
              'contractHash': 'sha256:${'c' * 64}',
            },
          });
        }
        if (req.url.path.contains('/bundles/')) return http.Response.bytes([1, 2, 3], 200);
        return jsonResponse({'dataRev': 1, 'results': {}});
      }));

      final m = await api.manifest('zhkh');
      expect(m.revision, 4);
      expect(m.preview, const PreviewIdentity(buildId: 'build_1', baseRevision: 3));
      expect((await api.fetchBundle('zhkh', bundleA)).length, 3);
      await api.queryGroup('zhkh', 4, [
        {'name': 'q'}
      ], timezone: 'UTC');

      expect(paths, [
        'GET /api/plugins/mobile-surfaces/v1/previews/zhkh',
        'GET /api/plugins/mobile-surfaces/v1/previews/zhkh/bundles/${Uri.encodeComponent(bundleA)}',
        'POST /api/plugins/mobile-surfaces/v1/previews/zhkh/data',
      ]);
    });

    test('an app id from the network is checked before it reaches a path', () async {
      final api = PreviewApi(config(), client: MockClient((_) async => http.Response('{}', 200)));
      await expectLater(api.manifest('../etc'), throwsA(isA<ManifestException>()));
      await expectLater(api.challenge('A b'), throwsA(isA<ManifestException>()));
    });
  });

  test('cryptography package signs deterministically (guards the vector test above)', () async {
    final algo = Ed25519();
    final pair = await algo.newKeyPairFromSeed(List<int>.generate(32, (i) => i));
    final a = await algo.sign(utf8.encode('x'), keyPair: pair);
    final b = await algo.sign(utf8.encode('x'), keyPair: pair);
    expect(a.bytes, b.bytes);
  });
}
