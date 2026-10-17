import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';

/// Same fixtures the Python verifier is tested against (contracts/fixtures/bundles).
final Directory fixtures = Directory('../../contracts/fixtures/bundles');

void main() {
  final index = jsonDecode(File('${fixtures.path}/index.json').readAsStringSync()) as Map<String, dynamic>;

  group('shared fixtures', () {
    for (final entry in index.entries) {
      final c = entry.value as Map<String, dynamic>;
      test('${entry.key}: ${c['why']}', () {
        final bytes = File('${fixtures.path}/${c['file']}').readAsBytesSync();
        if (c['valid'] == true) {
          final v = verifyBundle(bytes, expectedId: c['bundleId'] as String);
          expect(v.entrypoint, 'index.html');
          expect(v.files.keys, contains('assets/style.css'));
        } else {
          // "error" names the rule the case exists for, so another check cannot reject it by accident.
          final rejected = isA<BundleException>().having(
            (e) => e.message,
            'message',
            c.containsKey('error') ? contains(c['error'] as String) : isA<String>(),
          );
          expect(() => verifyBundle(bytes, expectedId: c['bundleId'] as String), throwsA(rejected));
        }
      });
    }
  });

  group('checkBundlePath', () {
    for (final bad in ['../x', '/abs', 'a/../b', r'a\b', 'a//b', './x', 'bundle.json', 'sp ace', 'a/.', 'x\u0000']) {
      test('rejects ${jsonEncode(bad)}', () {
        expect(() => checkBundlePath(bad), throwsA(isA<BundleException>()));
      });
    }
    for (final ok in ['index.html', 'assets/app-1.js', 'a/b/c.d.e', 'fonts/Inter@2x.woff2']) {
      test('accepts $ok', () => checkBundlePath(ok));
    }
  });

  test('garbage is not a bundle', () {
    expect(() => verifyBundle(Uint8List.fromList(utf8.encode('nope')), expectedId: 'sha256:00'),
        throwsA(isA<BundleException>()));
  });
}
