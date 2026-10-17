import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/gateway_jobs_client.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A connection with an HTTPS gateway prefix and no dashboard: the jobs come
/// from the Gateway API (`/api/jobs`).
SavedConnection _gatewayOnly() => SavedConnection(
  id: 'c1',
  label: 'Server',
  host: 'hermes.example.test',
  port: 443,
  apiKey: 'key',
  useHttps: true,
  gatewayPrefix: '/hermes',
);

class _Server {
  final List<Map<String, dynamic>> jobs;
  final List<http.Request> writes = [];

  _Server(this.jobs);

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/api/jobs')) {
      return http.Response(jsonEncode({'jobs': jobs}), 200);
    }
    writes.add(request);
    if (request.method == 'POST' && path.endsWith('/api/jobs')) {
      return http.Response(jsonEncode({'job': {}, 'id': 'new-1'}), 200);
    }
    return http.Response(jsonEncode({'ok': true}), 200);
  }

  Map<String, dynamic> bodyOf(http.Request request) =>
      jsonDecode(request.body) as Map<String, dynamic>;
}

Future<_Server> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> jobs, {
  bool embedded = false,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(400, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final server = _Server(jobs);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: hermesTheme(Brightness.dark),
      home: CronScreen(
        connection: _gatewayOnly(),
        embedded: embedded,
        clientFactory: (connection) => GatewayJobsClient(
          connection,
          httpClient: MockClient(server.handle),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return server;
}

Map<String, dynamic> _job({
  String id = 'j1',
  String name = 'Morning digest',
  String prompt = 'Summarise the news',
  String schedule = '0 9 * * *',
  Object? deliver,
  String? next,
  String? last,
  bool noAgent = false,
}) => {
  'id': id,
  'name': name,
  'prompt': prompt,
  'schedule_display': schedule,
  'deliver': ?deliver,
  'next_run_at': ?next,
  'last_run_at': ?last,
  if (noAgent) 'no_agent': true,
};

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  group('delivery chips', () {
    testWidgets('say where each result goes, in the phone language', (
      tester,
    ) async {
      await _pump(tester, [
        _job(id: 'a', name: 'To telegram', deliver: 'telegram'),
        _job(id: 'b', name: 'Quiet one', deliver: 'local'),
        _job(id: 'c', name: 'Chat one', deliver: 'origin'),
        _job(id: 'd', name: 'Chat id one', deliver: 'telegram:12345:7'),
        _job(id: 'e', name: 'No field'),
      ]);

      expect(find.text('to Telegram'), findsNWidgets(2));
      expect(find.text('result is not sent'), findsOneWidget);
      expect(find.text('to its chat'), findsOneWidget);
    });

    testWidgets('are localized in Russian', (tester) async {
      await _pump(tester, [
        _job(deliver: 'telegram'),
      ], locale: const Locale('ru'));

      expect(find.text('в Telegram'), findsOneWidget);
    });
  });

  group('a gateway-only connection', () {
    testWidgets('has no runs drill-down: a tap edits the task', (tester) async {
      await _pump(tester, [_job()]);

      await tester.tap(find.text('Morning digest'));
      await tester.pumpAndSettle();

      expect(find.text('Edit task'), findsOneWidget);
      expect(find.text('No runs yet'), findsNothing);
    });

    testWidgets('shows next and last run as readable local times', (
      tester,
    ) async {
      await _pump(tester, [
        _job(next: '2031-03-04T09:30:00+00:00', last: '2030-12-31T23:10:00Z'),
      ]);

      // Not the raw ISO string the server sent.
      expect(find.textContaining('2031-03-04T'), findsNothing);
      expect(find.textContaining('T23:10'), findsNothing);
      expect(find.textContaining('Next: '), findsOneWidget);
      expect(find.textContaining('Last: '), findsOneWidget);
    });
  });

  group('adding a task', () {
    testWidgets('goes to Telegram unless the person picks otherwise', (
      tester,
    ) async {
      final server = await _pump(tester, []);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Name'), 'Digest');
      await tester.enterText(_field('Prompt'), 'Summarise');
      await tester.enterText(_field('Schedule'), 'every 2h');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final create = server.writes.single;
      expect(create.method, 'POST');
      expect(server.bodyOf(create)['deliver'], 'telegram');
      expect(server.bodyOf(create)['schedule'], 'every 2h');
    });

    testWidgets('can be kept inside Hermes only', (tester) async {
      final server = await _pump(tester, []);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Name'), 'Digest');
      await tester.enterText(_field('Prompt'), 'Summarise');
      await tester.enterText(_field('Schedule'), 'every 2h');
      await tester.tap(find.byKey(const Key('cron-deliver')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nowhere (stays only in Hermes)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(server.bodyOf(server.writes.single)['deliver'], 'local');
    });
  });

  group('editing a task', () {
    testWidgets('saving without a change sends nothing', (tester) async {
      final server = await _pump(tester, [_job(deliver: 'telegram:12345')]);

      await tester.tap(find.text('Morning digest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(server.writes, isEmpty);
    });

    testWidgets('sends only the field that changed, and keeps a delivery '
        'the app does not offer', (tester) async {
      final server = await _pump(tester, [_job(deliver: 'telegram:12345')]);

      await tester.tap(find.text('Morning digest'));
      await tester.pumpAndSettle();
      // The unknown delivery stays selectable instead of being lost.
      expect(find.text('Other: telegram:12345'), findsOneWidget);
      await tester.enterText(_field('Prompt'), 'Summarise less');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final patch = server.writes.single;
      expect(patch.method, 'PATCH');
      expect(server.bodyOf(patch), {'prompt': 'Summarise less'});
    });

    testWidgets('changing the delivery is sent', (tester) async {
      final server = await _pump(tester, [_job(deliver: 'local')]);

      await tester.tap(find.text('Morning digest'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cron-deliver')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Telegram').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(server.bodyOf(server.writes.single), {'deliver': 'telegram'});
    });
  });

  group('the card menu', () {
    testWidgets('offers Pause for a running task and Resume for a paused one', (
      tester,
    ) async {
      await _pump(tester, [
        _job(id: 'a', name: 'Active'),
        {..._job(id: 'b', name: 'Stopped'), 'state': 'paused'},
      ]);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      expect(find.text('Pause'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert).last);
      await tester.pumpAndSettle();
      expect(find.text('Resume'), findsOneWidget);
    });
  });

  group('embedded as the Tasks tab', () {
    testWidgets('has no app bar of its own', (tester) async {
      await _pump(tester, [_job()], embedded: true);

      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Morning digest'), findsOneWidget);
    });

    testWidgets('keeps its app bar when opened on its own', (tester) async {
      await _pump(tester, [_job()]);

      expect(find.byType(AppBar), findsOneWidget);
    });

    testWidgets('explains an empty list', (tester) async {
      await _pump(tester, [], embedded: true);

      expect(find.text('No tasks yet'), findsOneWidget);
      expect(find.textContaining('send the result to Telegram'), findsOneWidget);
    });
  });
}
