import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;

/// Captures the request URI so paging params can be asserted on the wire.
class _RecordingJsonClient extends http.BaseClient {
  final String Function(Uri uri) bodyFor;
  Uri? lastUri;

  _RecordingJsonClient({required this.bodyFor});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastUri = request.url;
    return http.StreamedResponse(
      Stream.value(utf8.encode(bodyFor(request.url))),
      200,
    );
  }
}

Map<String, dynamic> _row(String id) => {
  'id': id,
  'title': 'Chat $id',
  'model': 'gpt-oss-20b',
  'source': 'gateway',
  'message_count': 2,
  'is_active': true,
  'preview': 'hello',
  'started_at': 1750000000,
};

void main() {
  group('ApiClient.getSessionsPage', () {
    test('sends limit and offset query params', () async {
      final client = _RecordingJsonClient(
        bodyFor: (_) => jsonEncode({
          'object': 'list',
          'data': [_row('a')],
          'has_more': true,
        }),
      );
      final api = ApiClient(
        baseUrl: 'http://fixture.local',
        apiKey: 'fixture-key',
        httpClient: client,
      );

      await api.getSessionsPage(limit: 50, offset: 100);

      expect(client.lastUri!.queryParameters['limit'], '50');
      expect(client.lastUri!.queryParameters['offset'], '100');
    });

    test('parses has_more true', () async {
      final client = _RecordingJsonClient(
        bodyFor: (_) => jsonEncode({
          'object': 'list',
          'data': [_row('a'), _row('b')],
          'has_more': true,
        }),
      );
      final api = ApiClient(
        baseUrl: 'http://fixture.local',
        apiKey: 'fixture-key',
        httpClient: client,
      );

      final page = await api.getSessionsPage(limit: 2);

      expect(page.sessions, hasLength(2));
      expect(page.hasMore, isTrue);
    });

    test('parses has_more false on the last page', () async {
      final client = _RecordingJsonClient(
        bodyFor: (_) => jsonEncode({
          'object': 'list',
          'data': [_row('z')],
          'has_more': false,
        }),
      );
      final api = ApiClient(
        baseUrl: 'http://fixture.local',
        apiKey: 'fixture-key',
        httpClient: client,
      );

      final page = await api.getSessionsPage(limit: 50, offset: 50);

      expect(page.sessions.single.id, 'z');
      expect(page.hasMore, isFalse);
    });

    test('missing has_more is treated as no more pages', () async {
      final client = _RecordingJsonClient(
        bodyFor: (_) => jsonEncode({
          'object': 'list',
          'data': [_row('a')],
        }),
      );
      final api = ApiClient(
        baseUrl: 'http://fixture.local',
        apiKey: 'fixture-key',
        httpClient: client,
      );

      final page = await api.getSessionsPage();

      expect(page.hasMore, isFalse);
    });

    test('getSessions still returns the first page sessions', () async {
      final client = _RecordingJsonClient(
        bodyFor: (_) => jsonEncode({
          'object': 'list',
          'data': [_row('a'), _row('b')],
          'has_more': true,
        }),
      );
      final api = ApiClient(
        baseUrl: 'http://fixture.local',
        apiKey: 'fixture-key',
        httpClient: client,
      );

      final sessions = await api.getSessions();

      expect(sessions, hasLength(2));
      expect(sessions.map((s) => s.id), ['a', 'b']);
    });
  });

  group('ApiClient.getSessionById', () {
    test('pages until the exact id is found', () async {
      final uris = <Uri>[];
      final client = _RecordingJsonClient(
        bodyFor: (uri) {
          uris.add(uri);
          final offset = int.parse(uri.queryParameters['offset'] ?? '0');
          if (offset == 0) {
            return jsonEncode({
              'object': 'list',
              'data': [_row('a'), _row('b')],
              'has_more': true,
            });
          }
          return jsonEncode({
            'object': 'list',
            'data': [_row('target')],
            'has_more': false,
          });
        },
      );
      final api = ApiClient(
        baseUrl: 'http://fixture.local',
        apiKey: 'fixture-key',
        httpClient: client,
      );

      final session = await api.getSessionById('target');

      expect(session, isNotNull);
      expect(session!.id, 'target');
      expect(uris, hasLength(2));
      expect(uris[1].queryParameters['offset'], '2');
    });

    test(
      'continues past 500 rows while the server reports more pages',
      () async {
        final uris = <Uri>[];
        final client = _RecordingJsonClient(
          bodyFor: (uri) {
            uris.add(uri);
            final offset = int.parse(uri.queryParameters['offset'] ?? '0');
            if (offset < 500) {
              return jsonEncode({
                'object': 'list',
                'data': [
                  for (var index = 0; index < 50; index++)
                    _row('${offset + index}'),
                ],
                'has_more': true,
              });
            }
            return jsonEncode({
              'object': 'list',
              'data': [_row('target-after-500')],
              'has_more': false,
            });
          },
        );
        final api = ApiClient(
          baseUrl: 'http://fixture.local',
          apiKey: '',
          httpClient: client,
        );

        final session = await api.getSessionById('target-after-500');

        expect(session?.id, 'target-after-500');
        expect(uris, hasLength(11));
        expect(uris.last.queryParameters['offset'], '500');
      },
    );

    test('returns null once the last page is reached without the id', () async {
      final client = _RecordingJsonClient(
        bodyFor: (_) => jsonEncode({
          'object': 'list',
          'data': [_row('a')],
          'has_more': false,
        }),
      );
      final api = ApiClient(
        baseUrl: 'http://fixture.local',
        apiKey: 'fixture-key',
        httpClient: client,
      );

      expect(await api.getSessionById('missing'), isNull);
    });
  });
}
