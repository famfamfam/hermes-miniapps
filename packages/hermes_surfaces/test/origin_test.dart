import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';

void main() {
  final origin = AppOrigin.forApp('127_0_0_1_8787', 'utilities');
  final base = origin.origin;

  RequestDecision decide(String url, [String method = 'GET']) => classifyRequest(origin, url, method);

  group('own origin', () {
    test('entrypoint, asset, nested asset, query and fragment', () {
      expect(decide('$base/').verdict, RequestVerdict.serve);
      expect(decide('$base/').path, '');
      expect(decide('$base/index.html').path, 'index.html');
      expect(decide('$base/assets/app-1.js').path, 'assets/app-1.js');
      expect(decide('$base/assets/app.js?v=3#x').path, 'assets/app.js');
      expect(decide('$base/#/bills').verdict, RequestVerdict.serve);
    });

    test('percent-encoded names are decoded before the bundle lookup', () {
      expect(decide('$base/fonts/Inter%402x.woff2').path, 'fonts/Inter@2x.woff2');
    });

    test('other methods are refused', () {
      for (final m in ['POST', 'PUT', 'DELETE', 'OPTIONS', 'PATCH']) {
        expect(decide('$base/index.html', m).verdict, RequestVerdict.badMethod, reason: m);
      }
      expect(decide('$base/index.html', 'get').verdict, RequestVerdict.serve);
    });
  });

  group('everything else is refused, never thrown on', () {
    final foreign = <String, String>{
      'other host': 'https://evil.example/x',
      'plain http on our host': base.replaceFirst('https', 'http'),
      'other port': '$base:8443/index.html',
      'sibling app': 'https://other-app.${origin.host.split('.')[1]}.surfaces.invalid/index.html',
      'suffix trick': '$base.evil.com/index.html',
      'userinfo trick': 'https://${origin.host}@evil.example/x',
      'userinfo trick 2': 'https://evil.example@${origin.host.replaceFirst('utilities', 'x')}/x',
      'data url': 'data:text/html,<script>1</script>',
      'blob url': 'blob:https://x/1',
      'file url': 'file:///etc/passwd',
      'intent url': 'intent://x#Intent;scheme=https;end',
      'about': 'about:blank',
      'javascript': 'javascript:alert(1)',
    };
    for (final e in foreign.entries) {
      test(e.key, () {
        final v = decide(e.value).verdict;
        expect(v == RequestVerdict.foreign || v == RequestVerdict.malformed || v == RequestVerdict.badMethod, isTrue,
            reason: '${e.value} -> $v');
        expect(v, isNot(RequestVerdict.serve));
      });
    }

    final malformed = <String>[
      '$base/%zz',
      '$base/a%2',
      '$base/%',
      '$base/index.html%',
      'http://[',
      'https://exa mple.com',
      '',
      ':::',
      '$base/%E0%A4%A',
    ];
    for (final url in malformed) {
      test('malformed ${url.isEmpty ? '(empty)' : url}', () {
        late RequestDecision d;
        expect(() => d = decide(url), returnsNormally);
        expect(d.verdict, isNot(RequestVerdict.serve));
      });
    }

    test('paths that no bundle can contain are refused outright', () {
      // %2f is decoded after Uri normalisation, so "..%2f" survives as a real ".." segment here.
      for (final p in ['/a/%2e%2e%2fb', '/%2e%2e%2f%2e%2e%2finstalled.json', '/%5c', '/a/%5c..', '/a//b', '/a/', '/bundle.json']) {
        expect(decide('$base$p').verdict, RequestVerdict.malformed, reason: p);
      }
    });

    test('a literal backslash is a path separator, as in browsers', () {
      // Uri.parse rewrites "\" to "/" and then collapses dot segments, so these become plain lookup
      // keys inside the bundle; the encoded form (%5C) is refused in the test above.
      expect(decide('$base/a\\b').path, 'a/b');
      expect(decide('$base/..\\x').path, 'x');
    });

    test('dot segments that Uri normalises away are only a lookup key', () {
      // Plain and percent-encoded dot segments collapse to "/installed.json" before we see them.
      // The decision is "serve", but BundleStore.read hands out only files listed in bundle.json,
      // so nothing else on disk is reachable (covered in host_test.dart).
      for (final p in ['/../../installed.json', '/%2e%2e/%2e%2e/installed.json', '/a/../installed.json']) {
        final d = decide('$base$p');
        expect(d.verdict, RequestVerdict.serve, reason: p);
        expect(d.path, 'installed.json', reason: p);
      }
    });
  });
}
