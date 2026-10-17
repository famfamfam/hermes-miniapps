import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Produced by plugin/mobile_surfaces_core (approval.canonical_delete_message, pairing.encode) with the
// seed 0..31 used by approval_test.dart: server and phone must agree byte for byte.
const seedB64 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
const deleteSignatureB64 =
    'jzBl4CX0GhmWFdCVYCh1OYgQtlD0df/6CO7QyEAYeCGwnYtfqZQPs+N9aFl3zvdqpQwywDhVtQfiwIM7WDPJBQ==';
const connectionLine =
    'HAP1.eyJ1IjoiaHR0cHM6Ly9ob3N0LmV4YW1wbGU6ODQ0My9zZWNyZXRwYXRoL21zIiwiYyI6IkFBQUFBQUFBQUFBQUFBQUFBQUFBQUEifQ';
final bundleA = 'sha256:${'a' * 64}';

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

ServerConfig config() =>
    ServerConfig(baseUri: Uri.parse('http://127.0.0.1:18787'), token: 'secret-token', deviceId: 'dev1');

String deleteMessage({String app = 'zhkh', int rev = 7, String? bundle, String nonce = 'n0nce'}) =>
    canonicalDeleteMessage(appId: app, revision: rev, bundleId: bundle ?? bundleA, nonce: nonce);

void main() {
  group('the deletion message', () {
    test('has the documented layout and its own version line', () {
      expect(deleteMessage().split('\n'), [
        'ms-delete-v1',
        'app:zhkh',
        'revision:7',
        'bundle:$bundleA',
        'nonce:n0nce',
      ]);
      expect(deleteMessage().endsWith('\n'), isFalse);
      expect(deleteMessage().startsWith('ms-approve-v1'), isFalse);
    });

    test('the same seed signs it exactly as Python does', () async {
      final key = await ApproverKey.fromSeed(Uint8List.fromList(base64Decode(seedB64)));
      expect(await key.sign(deleteMessage()), deleteSignatureB64);
    });
  });

  group('deleting an app', () {
    late ApproverKey key;
    setUp(() async => key = await ApproverKey.fromSeed(Uint8List.fromList(base64Decode(seedB64))));

    Map<String, dynamic> honest({String app = 'zhkh', int rev = 7, String? bundle, String nonce = 'n0nce'}) => {
      'appId': app,
      'revision': rev,
      'bundleId': bundle ?? bundleA,
      'nonce': nonce,
      'message': deleteMessage(app: app, rev: rev, bundle: bundle, nonce: nonce),
    };

    ReviewClient client(Map<String, dynamic> Function() challenge, List<http.Request> seen, {int deleteStatus = 200}) {
      final mock = MockClient((req) async {
        seen.add(req);
        if (req.url.path.endsWith('/delete/challenge')) return jsonResponse(challenge());
        if (req.url.path.endsWith('/delete')) {
          return jsonResponse(deleteStatus == 200 ? {'status': 'deleted'} : {'error': 'no'}, deleteStatus);
        }
        return http.Response('{}', 404);
      });
      return ReviewClient(SurfacesApi(config(), client: mock), key);
    }

    test('asks, signs what was asked and posts the signature with the nonce', () async {
      final seen = <http.Request>[];
      await client(() => honest(), seen).deleteApp('zhkh', revision: 7);

      expect(seen.map((r) => '${r.method} ${r.url.path}'), [
        'POST $apiPrefix/apps/zhkh/delete/challenge',
        'POST $apiPrefix/apps/zhkh/delete',
      ]);
      expect(jsonDecode(seen.last.body), {'nonce': 'n0nce', 'signature': deleteSignatureB64});
      expect(seen.last.headers['Authorization'], 'Bearer secret-token');
    });

    test('takes the bundle from the challenge and signs it', () async {
      final seen = <http.Request>[];
      final other = 'sha256:${'b' * 64}';
      await client(() => honest(bundle: other), seen).deleteApp('zhkh', revision: 7);
      final posted = jsonDecode(seen.last.body) as Map<String, dynamic>;
      expect(posted['signature'], await key.sign(deleteMessage(bundle: other)));
    });

    test('refuses an app or revision other than the one the user saw, and signs nothing', () async {
      for (final tampered in [honest(rev: 8), honest(app: 'other_app')]) {
        final seen = <http.Request>[];
        await expectLater(
          client(() => tampered, seen).deleteApp('zhkh', revision: 7),
          throwsA(isA<ApprovalFailure>().having((e) => e.key, 'key', SurfacesText.approvalDeleteChanged)),
        );
        expect(seen.where((r) => !r.url.path.endsWith('/challenge')), isEmpty);
      }
    });

    test('refuses a message that does not match its own fields', () async {
      final seen = <http.Request>[];
      final tampered = honest()..['message'] = deleteMessage(nonce: 'someone_elses');
      await expectLater(client(() => tampered, seen).deleteApp('zhkh', revision: 7), throwsA(isA<ApprovalFailure>()));
      // A publication message in its place is refused as well: the layouts differ.
      final publishStyle = honest()
        ..['message'] = canonicalApprovalMessage(
          appId: 'zhkh', buildId: 'build_1', draftRev: 7, bundleId: bundleA, baseRevision: 0, nonce: 'n0nce');
      await expectLater(client(() => publishStyle, seen).deleteApp('zhkh', revision: 7), throwsA(isA<ApprovalFailure>()));
      expect(seen.where((r) => !r.url.path.endsWith('/challenge')), isEmpty);
    });

    test('missing or wrong-typed challenge fields never authorize a deletion', () async {
      for (final field in ['appId', 'revision', 'bundleId', 'nonce', 'message']) {
        for (final value in <Object?>[null, field == 'revision' ? '7' : 7]) {
          final seen = <http.Request>[];
          final tampered = honest()..[field] = value;
          await expectLater(
            client(() => tampered, seen).deleteApp('zhkh', revision: 7),
            throwsA(isA<ApprovalFailure>()),
            reason: '$field: $value',
          );
          expect(seen.where((r) => !r.url.path.endsWith('/challenge')), isEmpty);
        }
      }
    });

    test('the server refusing the signature surfaces as the API error', () async {
      final c = client(() => honest(), [], deleteStatus: 422);
      await expectLater(
        c.deleteApp('zhkh', revision: 7),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 422)),
      );
    });

    test('an app id from the network is checked before it reaches a path', () async {
      final seen = <http.Request>[];
      await expectLater(client(() => honest(), seen).deleteApp('../etc', revision: 1), throwsA(isA<ManifestException>()));
      expect(seen, isEmpty);
    });
  });

  group('the connection line', () {
    test('reads the address and the code and shows only the host', () {
      final parsed = ConnectionString.tryParse(connectionLine)!;
      expect(parsed.baseUri.toString(), 'https://host.example:8443/secretpath/ms');
      expect(parsed.code, 'A' * 22);
      expect(parsed.host, 'host.example:8443');
      expect(parsed.host, isNot(contains('secretpath')));
    });

    test('reads the current form of the line, which does not start with the mark of a JWT', () {
      // Produced by plugin/mobile_surfaces_core/pairing.py: a space after the brace keeps the base64 from starting with
      // `eyJ`, which an agent's terminal masks. The phone must read both this and the older form above.
      const current =
          'HAP1.eyAidSI6Imh0dHBzOi8vaG9zdC5leGFtcGxlOjg0NDMvc2VjcmV0cGF0aC9tcyIsImMiOiJBQUFBQUFBQUFBQUFBQUFBQUFBQUFBIn0';
      expect(current.startsWith('HAP1.eyJ'), isFalse);
      final parsed = ConnectionString.tryParse(current)!;
      expect(parsed.baseUri.toString(), 'https://host.example:8443/secretpath/ms');
      expect(parsed.code, 'A' * 22);
      expect(ConnectionString.tryParse(connectionLine)!.baseUri, parsed.baseUri, reason: 'the older form still works');
    });

    test('is found inside a pasted message and tolerates padding', () {
      expect(ConnectionString.tryParse('Вот ваша строка:\n  $connectionLine\nВставьте её в приложение.'), isNotNull);
      expect(ConnectionString.tryParse('$connectionLine=='), isNotNull);
      expect(ConnectionString.tryParse('HAP1.eyJ1IjoiaHR0cDovLzEyNy4wLjAuMTo4Nzg3IiwiYyI6Ilp6MDlfLWtra2tra2tra2tra2tra2sifQ')!.host,
          '127.0.0.1:8787');
    });

    test('anything else is not a connection line', () {
      final unusable = <String?>[
        null, '', 'hello', 'HAP1.', 'HAP1.@@@', 'HAP2.${connectionLine.substring(5)}',
        'HAP1.${base64Url.encode(utf8.encode('[]'))}',
        'HAP1.${base64Url.encode(utf8.encode(jsonEncode({'u': 'ftp://h/ms', 'c': 'A' * 22})))}',
        'HAP1.${base64Url.encode(utf8.encode(jsonEncode({'u': 'https://u:p@h/ms', 'c': 'A' * 22})))}',
        'HAP1.${base64Url.encode(utf8.encode(jsonEncode({'u': 'https://h/ms?x=1', 'c': 'A' * 22})))}',
        'HAP1.${base64Url.encode(utf8.encode(jsonEncode({'u': 'https://h/ms#f', 'c': 'A' * 22})))}',
        'HAP1.${base64Url.encode(utf8.encode(jsonEncode({'u': 'https://h/ms', 'c': 'short'})))}',
        'HAP1.${base64Url.encode(utf8.encode(jsonEncode({'u': 'https://h/ms', 'c': 5})))}',
        'HAP1.${base64Url.encode(utf8.encode(jsonEncode({'u': 5, 'c': 'A' * 22})))}',
      ];
      for (final text in unusable) {
        expect(ConnectionString.tryParse(text), isNull, reason: '$text');
      }
    });
  });

  group('spending a code', () {
    final base = Uri.parse('https://host.example:8443/secretpath/ms/');

    Future<ClaimResult> claim(http.Client client) => claimConnectionCode(
      baseUri: base,
      code: 'A' * 22,
      deviceId: 'phone-ab12cd34',
      publicKeyBase64: 'pub=',
      client: client,
    );

    test('posts the code and the key with no bearer and returns the token', () async {
      http.Request? sent;
      final out = await claim(MockClient((req) async {
        sent = req;
        return jsonResponse({'token': ' tok-123-abc ', 'approverPaired': true});
      }));
      expect(sent!.url.toString(), 'https://host.example:8443/secretpath/ms$apiPrefix/devices/claim');
      expect(sent!.method, 'POST');
      expect(sent!.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(sent!.body), {'code': 'A' * 22, 'deviceId': 'phone-ab12cd34', 'publicKey': 'pub='});
      expect(sent!.followRedirects, isFalse);
      expect(out.token, 'tok-123-abc');
      expect(out.approverPaired, isTrue);
    });

    test('another approver is reported, not hidden', () async {
      final out = await claim(MockClient((_) async => jsonResponse({'token': 'tok', 'approverPaired': false})));
      expect(out.approverPaired, isFalse);
    });

    for (final status in [400, 404, 429]) {
      test('a $status answer is an ApiException carrying the status', () async {
        await expectLater(
          claim(MockClient((_) async => jsonResponse({'error': 'refused'}, status))),
          throwsA(isA<ApiException>().having((e) => e.status, 'status', status)),
        );
      });
    }

    test('a redirect is refused and never followed', () async {
      await expectLater(
        claim(MockClient((_) async => http.Response('', 302, headers: {'location': 'https://elsewhere.example/'}))),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 302)),
      );
    });

    test('no answer, or an answer that is not the plugin, counts as offline', () async {
      await expectLater(
        claim(MockClient((_) async => throw http.ClientException('down'))),
        throwsA(isA<OfflineException>()),
      );
      for (final body in <Object>['<html>portal</html>', {'token': ''}, {'token': 5}, {'token': 'a\nb'}, {'x': 1}, []]) {
        await expectLater(
          claim(MockClient((_) async => body is String
              ? http.Response(body, 200)
              : jsonResponse(body))),
          throwsA(isA<OfflineException>()),
          reason: '$body',
        );
      }
    });

    test('an unusable address is refused before anything is sent', () async {
      var sent = false;
      await expectLater(
        claimConnectionCode(
          baseUri: Uri.parse('https://u:p@host.example/ms'),
          code: 'A' * 22,
          deviceId: 'd',
          publicKeyBase64: 'k',
          client: MockClient((_) async {
            sent = true;
            return jsonResponse({});
          }),
        ),
        throwsArgumentError,
      );
      expect(sent, isFalse);
    });
  });
}
