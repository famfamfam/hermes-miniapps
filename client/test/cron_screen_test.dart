import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
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
  final List<Map<String, dynamic>> sessions;
  final List<http.Request> writes = [];

  /// When set, every write is refused with this reason (HTTP 400).
  String? refuseWith;

  _Server(this.jobs, {this.sessions = const []});

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/api/jobs')) {
      return http.Response(jsonEncode({'jobs': jobs}), 200);
    }
    if (request.method == 'GET' && path.endsWith('/api/sessions')) {
      return http.Response(jsonEncode({'data': sessions, 'has_more': false}), 200);
    }
    writes.add(request);
    if (refuseWith != null) {
      return http.Response(jsonEncode({'error': refuseWith}), 400);
    }
    if (request.method == 'POST' && path.endsWith('/api/jobs')) {
      return http.Response(jsonEncode({'job': {}, 'id': 'new-1'}), 200);
    }
    return http.Response(jsonEncode({'ok': true}), 200);
  }

  Map<String, dynamic> bodyOf(http.Request request) =>
      jsonDecode(request.body) as Map<String, dynamic>;
}

class _Dashboard extends DashboardClient {
  final List<Map<String, dynamic>> jobs;
  final List<Map<String, dynamic>> updates = [];
  int creates = 0;
  String? createdDelivery;

  _Dashboard(this.jobs) : super(host: 'example.test');

  @override
  Future<List<Map<String, dynamic>>> getCronJobs() async => jobs;

  @override
  Future<Map<String, dynamic>> createJob({
    required String prompt,
    required String schedule,
    String name = '',
    String deliver = 'local',
  }) async {
    creates++;
    createdDelivery = deliver;
    return {'id': 'new-1'};
  }

  @override
  Future<Map<String, dynamic>> updateJob(
    String jobId,
    Map<String, dynamic> fields, {
    Duration timeout = ApiClient.requestTimeout,
  }) async {
    updates.add(fields);
    return {};
  }
}

Future<void> _pumpDashboard(WidgetTester tester, _Dashboard dashboard) async {
  tester.view.physicalSize = const Size(400, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: hermesTheme(Brightness.dark),
      home: CronScreen(
        connection: _gatewayOnly(),
        clientFactory: (_) => dashboard,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<_Server> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> jobs, {
  bool embedded = false,
  Locale locale = const Locale('en'),
  List<Map<String, dynamic>> sessions = const [],
}) async {
  tester.view.physicalSize = const Size(400, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final server = _Server(jobs, sessions: sessions);
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

/// A job card tap now expands the run drill-down on every backend, so the
/// edit dialog opens through the card menu.
Future<void> _openEdit(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit').last);
  await tester.pumpAndSettle();
}

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
    testWidgets('lists its runs from the session history', (tester) async {
      await _pump(tester, [_job()], sessions: [
        {
          'id': 'cron_j1_1795333517',
          'title': 'Cron Job: Morning digest',
          'preview': 'result text',
          'last_active': 1795333517,
        },
        {'id': 'chat_1', 'title': 'An ordinary chat', 'preview': 'hi'},
        {'id': 'cron_other_1', 'title': 'Another job', 'preview': 'x'},
      ]);

      await tester.tap(find.text('Morning digest'));
      await tester.pumpAndSettle();

      expect(find.text('Cron Job: Morning digest'), findsOneWidget);
      expect(find.text('An ordinary chat'), findsNothing);
      expect(find.text('Another job'), findsNothing);
    });

    testWidgets('says when a job has no runs yet', (tester) async {
      await _pump(tester, [_job()], sessions: [
        {'id': 'chat_1', 'title': 'An ordinary chat', 'preview': 'hi'},
      ]);

      await tester.tap(find.text('Morning digest'));
      await tester.pumpAndSettle();

      expect(find.text('No runs yet.'), findsOneWidget);
    });

    test('run listing keeps only that job\'s sessions, newest first', () async {
      final client = GatewayJobsClient(
        _gatewayOnly(),
        httpClient: MockClient((request) async {
          expect(request.url.path.endsWith('/api/sessions'), isTrue);
          expect(request.url.queryParameters['limit'], '200');
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'cron_j1_2', 'title': 'newer'},
                {'id': 'chat_1', 'title': 'chat'},
                {'id': 'cron_j2_1', 'title': 'other job'},
                {'id': 'cron_j1_1', 'title': 'older'},
              ],
              'has_more': false,
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final runs = await client.getCronJobRuns('j1');
      expect(runs.map((session) => session.id), ['cron_j1_2', 'cron_j1_1']);
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

    testWidgets('can explicitly send to Telegram and push', (tester) async {
      final server = await _pump(tester, []);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Name'), 'Digest');
      await tester.enterText(_field('Prompt'), 'Summarise');
      await tester.enterText(_field('Schedule'), 'every 2h');
      await tester.tap(find.byKey(const Key('cron-deliver')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Telegram + push').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('OneSignal must be set up'), findsOneWidget);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(server.bodyOf(server.writes.single)['deliver'], 'telegram,onesignal');
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

  group('dashboard script-only tasks', () {
    testWidgets('can create a task for Telegram and push', (tester) async {
      final dashboard = _Dashboard([]);
      await _pumpDashboard(tester, dashboard);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Name'), 'Digest');
      await tester.enterText(_field('Prompt'), 'Summarise');
      await tester.enterText(_field('Schedule'), 'every 2h');
      await tester.tap(find.byKey(const Key('cron-deliver')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Telegram + push').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(dashboard.createdDelivery, 'telegram,onesignal');
    });

    testWidgets('creation cannot leave a partially configured task', (
      tester,
    ) async {
      final dashboard = _Dashboard([]);
      await _pumpDashboard(tester, dashboard);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('Script only (no agent)'), findsNothing);
      await tester.enterText(_field('Name'), 'Digest');
      await tester.enterText(_field('Prompt'), 'Summarise');
      await tester.enterText(_field('Schedule'), 'every 2h');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(dashboard.creates, 1);
      expect(dashboard.updates, isEmpty);
    });

    testWidgets('validation uses the edited script-only mode', (tester) async {
      final dashboard = _Dashboard([_job(prompt: '', noAgent: true)]);
      await _pumpDashboard(tester, dashboard);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(dashboard.updates, isEmpty);
      expect(
        find.text('Name, prompt, and schedule are required'),
        findsOneWidget,
      );
      await tester.enterText(_field('Prompt'), 'Run as agent');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(dashboard.updates.single['no_agent'], false);
    });

    testWidgets('switching to script-only permits an empty prompt', (
      tester,
    ) async {
      final dashboard = _Dashboard([_job()]);
      await _pumpDashboard(tester, dashboard);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.enterText(_field('Prompt'), '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(dashboard.updates.single, {'prompt': '', 'no_agent': true});
    });
  });

  group('editing a task', () {
    testWidgets('saving without a change sends nothing', (tester) async {
      final server = await _pump(tester, [_job(deliver: 'telegram:12345')]);

      await _openEdit(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(server.writes, isEmpty);
    });

    testWidgets('sends only the field that changed, and keeps a delivery '
        'the app does not offer', (tester) async {
      final server = await _pump(tester, [_job(deliver: 'telegram:12345')]);

      await _openEdit(tester);
      // The unknown delivery stays selectable instead of being lost.
      expect(find.text('Other: telegram:12345'), findsOneWidget);
      await tester.enterText(_field('Prompt'), 'Summarise less');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final patch = server.writes.single;
      expect(patch.method, 'PATCH');
      expect(server.bodyOf(patch), {'prompt': 'Summarise less'});
    });

    testWidgets('a script-only task has no prompt and can still be renamed', (
      tester,
    ) async {
      final server = await _pump(tester, [
        _job(name: 'Backup monitor', prompt: '', noAgent: true),
      ]);

      await _openEdit(tester);
      await tester.enterText(_field('Name'), 'Backup check');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(server.bodyOf(server.writes.single), {'name': 'Backup check'});
    });

    testWidgets('does not offer script-only, which the gateway refuses', (
      tester,
    ) async {
      await _pump(tester, [_job()]);

      await _openEdit(tester);

      expect(find.text('Edit task'), findsOneWidget);
      expect(find.text('Script only (no agent)'), findsNothing);
    });

    testWidgets('a refusal says why', (tester) async {
      final server = await _pump(tester, [_job()]);
      server.refuseWith = 'Prompt blocked: unsafe content';

      await _openEdit(tester);
      await tester.enterText(_field('Prompt'), 'Something else');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Prompt blocked: unsafe content'),
        findsOneWidget,
      );
    });

    testWidgets('push delivery can be changed and preserved', (tester) async {
      final server = await _pump(tester, [_job(deliver: 'onesignal')]);
      expect(find.text('Push (OneSignal)'), findsOneWidget);
      await _openEdit(tester);
      await tester.enterText(_field('Name'), 'Push digest');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(server.bodyOf(server.writes.single), {'name': 'Push digest'});
    });

    testWidgets('changing the delivery is sent', (tester) async {
      final server = await _pump(tester, [_job(deliver: 'local')]);

      await _openEdit(tester);
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
      expect(
        find.textContaining('send the result to Telegram'),
        findsOneWidget,
      );
    });
  });
}
