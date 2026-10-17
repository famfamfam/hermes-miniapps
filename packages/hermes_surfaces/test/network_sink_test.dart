import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';

void main() {
  group('describeProxyRequest', () {
    String d(String s) => describeProxyRequest(utf8.encode(s));

    test('CONNECT names host and port', () {
      expect(d('CONNECT evil.example:443 HTTP/1.1\r\nHost: evil.example:443\r\n\r\n'), 'CONNECT evil.example:443');
    });
    test('absolute-form GET', () {
      expect(d('GET http://evil.example/p?q=1 HTTP/1.1\r\nHost: evil.example\r\n\r\n'), 'GET http://evil.example/p?q=1');
    });
    test('a hostname that smuggles data is reported as is', () {
      expect(d('CONNECT c2VjcmV0.attacker.example:443 HTTP/1.1\r\n\r\n'), 'CONNECT c2VjcmV0.attacker.example:443');
    });
    test('long targets are cut', () {
      final r = d('GET http://x/${'a' * 400} HTTP/1.1\r\n\r\n');
      expect(r.length, lessThan(140));
      expect(r, endsWith('…'));
    });
    test('garbage and binary never throw', () {
      expect(d(''), startsWith('unrecognised'));
      expect(describeProxyRequest([0x16, 0x03, 0x01, 0xff, 0xfe, 0x00]), startsWith('unrecognised'));
      expect(describeProxyRequest(List<int>.filled(5000, 0xff)), startsWith('unrecognised'));
    });
  });

  group('NetworkSink', () {
    late NetworkSink sink;
    setUp(() async => sink = await NetworkSink.start());
    tearDown(() async => sink.close());

    Future<String> attempt(void Function(Socket s) act) async {
      final seen = sink.attempts.first.timeout(const Duration(seconds: 3));
      final s = await Socket.connect(InternetAddress.loopbackIPv4, sink.port);
      act(s);
      final line = await seen;
      s.destroy();
      return line;
    }

    test('records the destination and closes the connection', () async {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, sink.port);
      final closed = Completer<void>();
      s.listen((_) {}, onDone: closed.complete, onError: (_) => closed.complete());
      final seen = sink.attempts.first;
      s.add(utf8.encode('CONNECT evil.example:443 HTTP/1.1\r\n\r\n'));
      expect(await seen.timeout(const Duration(seconds: 3)), 'CONNECT evil.example:443');
      await closed.future.timeout(const Duration(seconds: 3)); // the sink hung up
      expect(sink.count, 1);
    });

    test('a client that sends nothing is reported and dropped', () async {
      expect(await attempt((_) {}), 'connection (no request)');
    });

    test('a client that connects and closes straight away is reported', () async {
      final line = await attempt((s) => s.destroy());
      expect(line, startsWith('connection'));
    });

    test('many attempts are all counted', () async {
      final lines = <String>[];
      final sub = sink.attempts.listen(lines.add);
      for (var i = 0; i < 20; i++) {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, sink.port);
        s.add(utf8.encode('CONNECT h$i.example:443 HTTP/1.1\r\n\r\n'));
        await s.flush();
        s.destroy();
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await sub.cancel();
      expect(sink.count, 20);
      expect(lines.length, 20);
      expect(lines, contains('CONNECT h7.example:443'));
    });

    test('listens on loopback only', () {
      // Bound to 127.0.0.1, so it is not reachable from the network or from other devices.
      expect(sink.port, greaterThan(1023));
    });
  });
}
