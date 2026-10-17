// A mini-app's "send to Hermes" opens a chat whose first message goes out at once (the user already read and
// confirmed the text inside the app). Text from the share sheet never does: it only fills the composer.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class _Server extends http.BaseClient {
  final bodies = <Map<String, dynamic>>[];
  StreamController<List<int>>? _stream;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      return _json({'data': []});
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/v1/chat/completions')) {
      bodies.add(
        jsonDecode((request as http.Request).body) as Map<String, dynamic>,
      );
      _stream = StreamController<List<int>>();
      return http.StreamedResponse(
        _stream!.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    return _json({'error': 'unexpected'}, 404);
  }

  void finish() {
    final stream = _stream;
    if (stream == null || stream.isClosed) return;
    stream
      ..add(utf8.encode('data: [DONE]\n\n'))
      ..close();
  }

  http.StreamedResponse _json(Object body, [int status = 200]) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        status,
        headers: {'content-type': 'application/json'},
      );
}

Future<void> _open(
  WidgetTester tester,
  _Server server, {
  required String text,
  required bool send,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(
        connection: SavedConnection(
          id: 'initial-text',
          label: 'Fixture',
          host: 'fixture.example',
          port: 8642,
          apiKey: 'synthetic-test-key',
        ),
        session: Session(
          id: 'initial-text-session',
          title: 'New chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
          isLocalDraft: true,
        ),
        testApiClient: ApiClient(
          baseUrl: 'http://fixture.example',
          apiKey: 'synthetic-test-key',
          httpClient: server,
        ),
        initialComposerText: text,
        sendInitialText: send,
      ),
    ),
  );
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _wrapUp(WidgetTester tester, _Server server) async {
  server.finish();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'verbose_mode': false}));

  testWidgets(
    'the confirmed text goes out as the first message, exactly once',
    (tester) async {
      final server = _Server();
      await _open(
        tester,
        server,
        text: 'Разбери квитанцию\n\n— Sent from the app “Коммуналка”',
        send: true,
      );
      expect(server.bodies, hasLength(1));
      final messages = (server.bodies.single['messages'] as List).cast<Map>();
      expect(messages.last['role'], 'user');
      expect(
        messages.last['content'],
        'Разбери квитанцию\n\n— Sent from the app “Коммуналка”',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-message-composer')))
            .controller!
            .text,
        isEmpty,
        reason: 'the composer is cleared like after any send',
      );
      await _wrapUp(tester, server);
    },
  );

  testWidgets('text from the share sheet only fills the composer', (
    tester,
  ) async {
    final server = _Server();
    await _open(tester, server, text: 'shared text', send: false);
    expect(server.bodies, isEmpty);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('chat-message-composer')))
          .controller!
          .text,
      'shared text',
    );
    await _wrapUp(tester, server);
  });
}
