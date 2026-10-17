// A write by an untrusted MCP server raises approval.request on a plain streamed chat turn. The chat opens
// the approval dialog, answers it over REST, counts "back" as deny and closes the dialog when the turn ends.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/turn_notification_service.dart';
import 'package:hermes_android/core/widgets/chat_context_header.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/recording_turn_notification_sink.dart';

const _frame =
    'event: approval.request\n'
    'data: {"run_id": "chatcmpl-1", "request_id": "r1", '
    '"command": "MCP tool app_create on UNTRUSTED server surfaces", '
    '"description": "Approve to run once.", "choices": ["once", "deny"]}\n\n';

const _secondFrame =
    'event: approval.request\n'
    'data: {"run_id": "chatcmpl-1", "request_id": "r2", '
    '"command": "MCP tool data_sql on UNTRUSTED server surfaces", '
    '"description": "Approve to run once.", "choices": ["once", "deny"]}\n\n';

class _Server extends http.BaseClient {
  final approvals = <({String path, Map<String, dynamic> body})>[];

  /// Request ids Hermes no longer waits for: answering them gets a 409.
  final gone = <String>{};
  final postStarted = Completer<void>();
  StreamController<List<int>>? _stream;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      return _json({
        'data': [
          {'role': 'user', 'content': 'hello'},
          {'role': 'assistant', 'content': 'done'},
        ],
      });
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/v1/chat/completions')) {
      _stream = StreamController<List<int>>();
      if (!postStarted.isCompleted) postStarted.complete();
      return http.StreamedResponse(
        _stream!.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (request.method == 'POST' && request.url.path.endsWith('/approval')) {
      final body =
          jsonDecode((request as http.Request).body) as Map<String, dynamic>;
      approvals.add((path: request.url.path, body: body));
      if (gone.contains(body['request_id'])) {
        return _json({
          'error': {
            'message': 'Run has no pending approval',
            'code': 'approval_not_pending',
          },
        }, 409);
      }
      return _json({'object': 'hermes.run.approval_response', 'resolved': 1});
    }
    return _json({'error': 'unexpected'}, 404);
  }

  void emit(String text) => _stream!.add(utf8.encode(text));

  void finish() {
    if (_stream!.isClosed) return;
    _stream!
      ..add(utf8.encode('data: [DONE]\n\n'))
      ..close();
  }

  /// The connection dies mid-answer, as it does when Android pauses the network.
  void fail() => _stream!.addError(const SocketException('Synthetic break'));

  http.StreamedResponse _json(Object body, [int status = 200]) {
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      status,
      headers: {'content-type': 'application/json'},
    );
  }
}

Future<void> _openChatAndSend(
  WidgetTester tester,
  _Server server, {
  TurnNotificationService? notifications,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatScreen(
                    connection: SavedConnection(
                      id: 'approval-test',
                      label: 'Fixture',
                      host: 'fixture.example',
                      port: 8642,
                      apiKey: 'synthetic-test-key',
                    ),
                    session: Session(
                      id: 'approval-session',
                      title: 'Fixture chat',
                      model: 'fixture-model',
                      source: 'test',
                      messageCount: 0,
                      isActive: true,
                      preview: '',
                      startedAt: 1,
                    ),
                    testApiClient: ApiClient(
                      baseUrl: 'http://fixture.example',
                      apiKey: 'synthetic-test-key',
                      httpClient: server,
                    ),
                    testTurnNotifications: notifications,
                  ),
                ),
              ),
              child: const Text('open chat'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open chat'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('chat-message-composer')),
    'create the app',
  );
  await tester.pump();
  await tester.tap(find.byTooltip('Send'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  expect(server.postStarted.isCompleted, isTrue);
}

/// A chat that has sent its prompt and waits for the streamed answer.
Future<_Server> _startedChat(
  WidgetTester tester, {
  TurnNotificationService? notifications,
}) async {
  final server = _Server();
  await _openChatAndSend(tester, server, notifications: notifications);
  return server;
}

/// Ends the turn and takes the screen down, so no timer of a half-finished turn outlives the test.
Future<void> _wrapUp(WidgetTester tester, _Server server) async {
  server.finish();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  testWidgets('the dialog appears and "Allow once" answers over REST', (
    tester,
  ) async {
    final server = _Server();
    await _openChatAndSend(tester, server);
    server.emit(_frame);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Approval needed'), findsOneWidget);
    expect(find.textContaining('MCP tool app_create'), findsOneWidget);
    expect(server.approvals, isEmpty, reason: 'nothing is answered by itself');

    await tester.tap(find.byKey(const Key('approval-once')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(server.approvals, hasLength(1));
    expect(server.approvals.single.path, '/v1/runs/chatcmpl-1/approval');
    expect(server.approvals.single.body, {
      'request_id': 'r1',
      'choice': 'once',
    });
    expect(find.text('Approval needed'), findsNothing);
    await _wrapUp(tester, server);
  });

  testWidgets('back counts as deny and is sent once', (tester) async {
    final server = _Server();
    await _openChatAndSend(tester, server);
    server.emit(_frame);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Approval needed'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(server.approvals, hasLength(1));
    expect(server.approvals.single.body['choice'], 'deny');
    expect(find.byKey(const Key('chat-message-composer')), findsOneWidget);
    await _wrapUp(tester, server);
  });

  testWidgets(
    'the dialog closes by itself when the turn ends, and sends nothing',
    (tester) async {
      final server = _Server();
      await _openChatAndSend(tester, server);
      server.emit(_frame);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Approval needed'), findsOneWidget);

      server.finish();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Approval needed'), findsNothing);
      expect(
        server.approvals,
        isEmpty,
        reason: 'the run is over: nothing is left to answer',
      );
      expect(
        find.byKey(const Key('chat-message-composer')),
        findsOneWidget,
        reason: 'the chat screen itself must stay',
      );
    },
  );

  testWidgets(
    'a turn that ends right after an answer does not pop the chat screen',
    (tester) async {
      final server = _Server();
      await _openChatAndSend(tester, server);
      server.emit(_frame);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('approval-once')));
      await tester
          .pump(); // the answer is in flight; the dialog is about to close
      server.finish();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 600));

      expect(server.approvals, hasLength(1));
      expect(find.byKey(const Key('chat-message-composer')), findsOneWidget);
    },
  );

  testWidgets(
    'a turn that ends in the same moment the request arrives leaves no dialog behind',
    (tester) async {
      final server = await _startedChat(tester);
      // Both frames reach the app before the dialog route has been built: the
      // end of the turn finds nothing to close. The dialog must not outlive it.
      server.emit(_frame);
      server.finish();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Approval needed'), findsNothing);
      expect(server.approvals, isEmpty);
      expect(find.byKey(const Key('chat-message-composer')), findsOneWidget);
    },
  );

  testWidgets(
    'an answer Hermes no longer waits for closes the dialog with a calm notice',
    (tester) async {
      final server = await _startedChat(tester);
      server.gone.add('r1');
      server.emit(_frame);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('approval-once')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(server.approvals, hasLength(1));
      expect(find.text('Approval needed'), findsNothing);
      expect(find.textContaining('expired'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.textContaining('409'), findsNothing);
      await _wrapUp(tester, server);
    },
  );

  testWidgets('a second request waits behind the first and is shown next', (
    tester,
  ) async {
    final server = await _startedChat(tester);
    server.emit(_frame);
    server.emit(_secondFrame);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('app_create'), findsOneWidget);
    expect(find.textContaining('data_sql'), findsNothing);

    await tester.tap(find.byKey(const Key('approval-once')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Approval needed'), findsOneWidget);
    expect(find.textContaining('data_sql'), findsOneWidget);
    await tester.tap(find.byKey(const Key('approval-deny')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(server.approvals.map((a) => a.body['request_id']), ['r1', 'r2']);
    expect(server.approvals.map((a) => a.body['choice']), ['once', 'deny']);
    expect(find.text('Approval needed'), findsNothing);
    await _wrapUp(tester, server);
  });

  testWidgets('a request that expired lets the next one through', (
    tester,
  ) async {
    final server = await _startedChat(tester);
    server.gone.add('r1');
    server.emit(_frame);
    server.emit(_secondFrame);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('approval-once')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Approval needed'), findsOneWidget);
    expect(find.textContaining('data_sql'), findsOneWidget);
    await tester.tap(find.byKey(const Key('approval-once')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(server.approvals.map((a) => a.body['request_id']), ['r1', 'r2']);
    await _wrapUp(tester, server);
  });

  testWidgets('requests still queued when the turn ends are never shown', (
    tester,
  ) async {
    final server = await _startedChat(tester);
    server.emit(_frame);
    server.emit(_secondFrame);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('app_create'), findsOneWidget);

    server.finish();
    // Frame by frame: the queued request must not even flash up on its way out.
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        find.textContaining('data_sql'),
        findsNothing,
        reason: 'a request queued behind a finished turn is never built',
      );
    }

    expect(find.text('Approval needed'), findsNothing);
    expect(server.approvals, isEmpty);
  });

  testWidgets('the same request delivered twice is one question', (
    tester,
  ) async {
    final server = await _startedChat(tester);
    server.emit(_frame);
    server.emit(_frame);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('approval-once')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Approval needed'), findsNothing);
    expect(server.approvals, hasLength(1));
    await _wrapUp(tester, server);
  });

  testWidgets('a chat on a connection with no Projects has no context bar', (
    tester,
  ) async {
    final server = await _startedChat(tester);

    // Nothing to say: no Project to be unassigned from, no chosen reasoning,
    // and the connection is fine. The bar is left out, not drawn empty.
    expect(find.byType(ChatContextHeader), findsNothing);
    expect(find.text('Unassigned'), findsNothing);
    await _wrapUp(tester, server);
  });

  group('a streamed turn while the app is away', () {
    late RecordingTurnNotificationSink sink;
    late TurnNotificationService notifications;

    setUp(() {
      sink = RecordingTurnNotificationSink();
      notifications = TurnNotificationService(sink: sink);
    });

    // The lifecycle state outlives a test: always hand the next one a visible app.
    tearDown(() {
      final binding = TestWidgetsFlutterBinding.instance;
      if (binding.lifecycleState != AppLifecycleState.resumed) {
        for (final state in const [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          binding.handleAppLifecycleStateChanged(state);
        }
      }
    });

    // Android walks the whole lifecycle chain; skipping a step trips Flutter's
    // transition assertions.
    void foreground(WidgetTester tester) {
      for (final state in const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    void background(WidgetTester tester) {
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    Future<void> finishTurn(WidgetTester tester, _Server server) async {
      server.finish();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('announces the finished answer', (tester) async {
      final server = await _startedChat(tester, notifications: notifications);
      background(tester);
      await tester.pump();

      await finishTurn(tester, server);

      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.title, 'Hermes response ready');
      expect(sink.shown.single.body, contains('Fixture chat'));
      expect(sink.shown.single.payload, contains('approval-session'));
      await _wrapUp(tester, server);
    });

    testWidgets('says nothing while the app is on screen', (tester) async {
      final server = await _startedChat(tester, notifications: notifications);

      await finishTurn(tester, server);

      expect(sink.shown, isEmpty);
      await _wrapUp(tester, server);
    });

    testWidgets(
      'says nothing about a stream that broke, only about an answer',
      (tester) async {
        final server = await _startedChat(tester, notifications: notifications);
        background(tester);
        await tester.pump();

        server.fail();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(sink.shown, isEmpty);
        await _wrapUp(tester, server);
      },
    );

    testWidgets('asks for an approval, without buttons it could not honour', (
      tester,
    ) async {
      final server = await _startedChat(tester, notifications: notifications);
      background(tester);
      await tester.pump();

      server.emit(_frame);
      await tester.pump(const Duration(milliseconds: 100));

      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.title, contains('Approval needed'));
      expect(sink.shown.single.body, contains('app_create'));
      expect(sink.shown.single.actions, isEmpty);
      // The tap opens this chat: no request id to answer from the shade.
      expect(sink.shown.single.payload, isNot(contains('requestId')));
      await _wrapUp(tester, server);
    });

    testWidgets(
      'a repeated request is announced once, the next one is met on screen',
      (tester) async {
        final server = await _startedChat(tester, notifications: notifications);
        background(tester);
        await tester.pump();

        server.emit(_frame);
        server.emit(_frame);
        server.emit(_secondFrame);
        await tester.pump(const Duration(milliseconds: 100));
        // Only the one being asked is announced; the other waits its turn.
        expect(sink.shown, hasLength(1));
        expect(sink.shown.single.body, contains('app_create'));

        foreground(tester);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byKey(const Key('approval-once')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        // The app is on screen now: the second request is simply the next
        // dialog, with no notification beside it.
        expect(find.textContaining('data_sql'), findsOneWidget);
        expect(sink.shown, hasLength(1));
        await _wrapUp(tester, server);
      },
    );

    testWidgets('an approval with the app on screen needs no notification', (
      tester,
    ) async {
      final server = await _startedChat(tester, notifications: notifications);

      server.emit(_frame);
      await tester.pump(const Duration(milliseconds: 100));

      expect(sink.shown, isEmpty);
      await _wrapUp(tester, server);
    });
  });

  testWidgets(
    'a frame without an event key in its payload still opens the dialog',
    (tester) async {
      final server = _Server();
      await _openChatAndSend(tester, server);
      server.emit(
        'event: approval.request\n'
        'data: {"run_id": "chatcmpl-2", "request_id": "r9", '
        '"command": "MCP tool data_sql", "choices": ["once", "deny"]}\n\n',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Approval needed'), findsOneWidget);
      await tester.tap(find.byKey(const Key('approval-deny')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(server.approvals.single.path, '/v1/runs/chatcmpl-2/approval');
      expect(server.approvals.single.body['choice'], 'deny');
      await _wrapUp(tester, server);
    },
  );
}
