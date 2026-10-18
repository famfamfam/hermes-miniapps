// The host's answer to a tap on a button that writes: what is asked of the server, what the user is asked first, the
// key that makes a repeat safe, and the stable codes the page gets back when something is refused.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'locale_support.dart';

const origin = 'https://utilities.abcd1234.surfaces.invalid';

class Server {
  final requests = <http.Request>[];
  int revision = 7;
  Map<String, Object?> mutations = {
    'mark_paid': {
      'params': {'id': {'type': 'integer'}},
      'destructive': false,
    },
    'delete_bill': {
      'params': {'id': {'type': 'integer'}},
      'destructive': true,
      'label': 'Delete this bill',
    },
    'archive': {'params': <String, Object?>{}, 'destructive': false, 'confirm': true, 'label': 'Archive the month'},
    'wipe_old': {'params': <String, Object?>{}, 'destructive': true},
  };

  /// What the server answers to a mutation request; null: the usual success.
  FutureOr<http.Response> Function(http.Request)? onMutation;

  Iterable<http.Request> get posts => requests.where((r) => r.method == 'POST');
  Iterable<http.Request> get manifests => requests.where((r) => r.method == 'GET');
  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
  List<String> get keys => [for (final r in posts) body(r)['idempotencyKey'] as String];

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/apps/utilities')) {
      return http.Response(
          jsonEncode({
            'appId': 'utilities',
            'title': 'Коммуналка',
            'revision': revision,
            'epoch': 'e1',
            'bundle': {
              'bundleId': 'sha256:${'0' * 64}',
              'size': 10,
              'format': 1,
              'sdkMajor': 1,
              'capabilities': <String>[],
              'contractHash': 'sha256:${'1' * 64}',
            },
            'queries': <String, Object?>{},
            'mutations': mutations,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    if (request.method == 'POST' && path.contains('/mutations/')) {
      final custom = onMutation;
      if (custom != null) return await custom(request);
      return http.Response(
          jsonEncode({'revision': revision, 'epoch': 'e1', 'dataRev': 5, 'rowsAffected': 1, 'lastInsertId': null, 'replayed': false}),
          200);
    }
    return http.Response('{"error":"unexpected"}', 404);
  });
}

SurfacesHost makeHost(Server server, Directory tmp, {bool preview = false}) {
  final config = ServerConfig(baseUri: Uri.parse('http://127.0.0.1:8787'), token: 'tok', deviceId: 'dev');
  return SurfacesHost(
    api: preview ? PreviewApi(config.forPreview(), client: server.client) : SurfacesApi(config, client: server.client),
    bundles: BundleStore(Directory('${tmp.path}/b')),
    snapshots: SnapshotCache(Directory('${tmp.path}/s')),
  );
}

InstalledApp installed(Directory tmp, {int revision = 7}) => InstalledApp(
      appId: 'utilities',
      title: 'Коммуналка',
      bundleId: 'sha256:${'0' * 64}',
      revision: revision,
      contractHash: 'sha256:${'1' * 64}',
      epoch: 'e1',
      dir: tmp,
      files: const {'index.html'},
      entrypoint: 'index.html',
      installedAt: DateTime(2026, 10, 17),
    );

BridgeRequest req(Object rpc) =>
    BridgeGate(expectedOrigin: origin).accept(jsonEncode({'id': 1, 'rpc': rpc}), sourceOrigin: origin, isMainFrame: true);

Map<String, Object?> tap(String name, [Map<String, Object?>? args]) => {'op': 'mutate', 'name': name, 'args': ?args};

void main() {
  late Directory tmp;
  late Server server;
  late BuildContext context;
  late SurfacesHost host;
  var now = DateTime(2026, 10, 17, 12);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mutation_bridge');
    server = Server();
    host = makeHost(server, tmp);
    now = DateTime(2026, 10, 17, 12);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  MutationBridge bridge({bool preview = false}) =>
      MutationBridge(preview: preview, timezone: () => 'Europe/Moscow', clock: () => now);

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(localizedApp(
      locale: const Locale('en'),
      home: Scaffold(body: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })),
    ));
  }

  Future<Object?> run(MutationBridge b, Object rpc, {SurfacesHost? on, int revision = 7}) =>
      b.handle(req(rpc), host: on ?? host, app: installed(tmp, revision: revision), title: 'Коммуналка', context: context);

  Future<HostError> refused(Future<Object?> call) async {
    try {
      await call;
    } on HostError catch (e) {
      return e;
    }
    fail('expected a HostError');
  }

  http.Response failure(int status, String message, [String? code]) =>
      http.Response(jsonEncode({'error': message, 'code': ?code}), status);

  group('a button that does not delete', () {
    testWidgets('writes at once, with the app\'s revision and a key the host made, and tells the page only the result',
        (tester) async {
      await mount(tester);
      final out = await run(bridge(), tap('mark_paid', {'id': 2}));
      expect(out, {'done': true, 'rowsAffected': 1, 'lastInsertId': null, 'replayed': false});
      final sent = server.body(server.posts.single);
      expect(server.posts.single.url.path, endsWith('/apps/utilities/mutations/mark_paid'));
      expect(sent['revision'], 7);
      expect(sent['args'], {'id': 2});
      expect(sent['timezone'], 'Europe/Moscow');
      expect(sent['idempotencyKey'], matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
      expect(server.posts.single.headers['Authorization'], 'Bearer tok');
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the manifest is fetched once per installed version', (tester) async {
      await mount(tester);
      final b = bridge();
      await run(b, tap('mark_paid', {'id': 2}));
      await run(b, tap('mark_paid', {'id': 3}));
      expect(server.manifests, hasLength(1));
      expect(server.posts, hasLength(2));
    });

    testWidgets('each action gets its own key', (tester) async {
      await mount(tester);
      final b = bridge();
      await run(b, tap('mark_paid', {'id': 2}));
      await run(b, tap('mark_paid', {'id': 2}));
      expect(server.keys.toSet(), hasLength(2), reason: 'a second, separate tap is a second action');
    });

    testWidgets('what the server inserted and whether it was a repeat reach the page', (tester) async {
      await mount(tester);
      server.onMutation = (_) => http.Response(
          jsonEncode({'dataRev': 6, 'rowsAffected': 1, 'lastInsertId': 19, 'replayed': true}), 200);
      expect(await run(bridge(), tap('mark_paid', {'id': 2})),
          {'done': true, 'rowsAffected': 1, 'lastInsertId': 19, 'replayed': true});
    });
  });

  group('what the user is asked first', () {
    testWidgets('anything that deletes shows the server\'s words, the arguments, and sends nothing before the tap',
        (tester) async {
      await mount(tester);
      final call = run(bridge(), tap('delete_bill', {'id': 3}));
      await tester.pumpAndSettle();
      expect(find.text('Delete data?'), findsOneWidget);
      expect(find.textContaining('Delete this bill'), findsOneWidget);
      expect(find.textContaining('Коммуналка'), findsOneWidget);
      expect(tester.widget<SelectableText>(find.descendant(of: find.byKey(const ValueKey('mutation-args')), matching: find.byType(SelectableText))).data,
          'id: 3');
      expect(server.posts, isEmpty);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect((await call as Map)['done'], true);
      expect(server.posts, hasLength(1));
    });

    testWidgets('Cancel writes nothing and says so', (tester) async {
      await mount(tester);
      final call = run(bridge(), tap('delete_bill', {'id': 3}));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await call, {'done': false});
      expect(server.posts, isEmpty);
    });

    testWidgets('an author can ask for a confirmation even where nothing is deleted', (tester) async {
      await mount(tester);
      final call = run(bridge(), tap('archive'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm the change'), findsOneWidget);
      expect(find.textContaining('Archive the month'), findsOneWidget);
      expect(find.text('Delete data?'), findsNothing);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect((await call as Map)['done'], true);
    });

    testWidgets('without a label the name is made readable, and the page\'s words are never the ones shown', (tester) async {
      await mount(tester);
      final call = run(bridge(), tap('wipe_old'));
      await tester.pumpAndSettle();
      expect(find.textContaining('wipe old'), findsOneWidget);
      expect(find.byKey(const ValueKey('mutation-args')), findsNothing, reason: 'no arguments, no argument box');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await call;
    });

    testWidgets('long argument values are cut in the window', (tester) async {
      await mount(tester);
      server.mutations = {
        'note_bill': {'params': {'note': {'type': 'string'}}, 'destructive': false, 'confirm': true},
      };
      final call = run(bridge(), tap('note_bill', {'note': 'x' * 500}));
      await tester.pumpAndSettle();
      final shown = tester.widget<SelectableText>(find.descendant(of: find.byKey(const ValueKey('mutation-args')), matching: find.byType(SelectableText))).data!;
      expect(shown.length, lessThan(80));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await call;
    });
  });

  group('what is refused before anything is sent', () {
    testWidgets('a preview saves nothing and asks nothing', (tester) async {
      await mount(tester);
      final e = await refused(run(bridge(preview: true), tap('delete_bill', {'id': 3}), on: makeHost(server, tmp, preview: true)));
      expect(e.code, 'preview_blocked');
      expect(server.requests, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a name the server does not list', (tester) async {
      await mount(tester);
      final e = await refused(run(bridge(), tap('drop_everything')));
      expect(e.code, 'unknown_mutation');
      expect(server.posts, isEmpty);
    });

    testWidgets('a page that runs an older revision than the server has', (tester) async {
      await mount(tester);
      server.revision = 8;
      final e = await refused(run(bridge(), tap('mark_paid', {'id': 2})));
      expect(e.code, 'stale_revision');
      expect(server.posts, isEmpty);
    });

    testWidgets('no connection: nothing is sent and nothing is queued', (tester) async {
      await mount(tester);
      host.connectivity.value = Connectivity.offline;
      final e = await refused(run(bridge(), tap('mark_paid', {'id': 2})));
      expect(e.code, 'offline');
      expect(server.requests, isEmpty);
    });

    testWidgets('a second identical tap while the first is still being handled', (tester) async {
      await mount(tester);
      final gate = Completer<http.Response>();
      server.onMutation = (_) => gate.future;
      final b = bridge();
      final first = run(b, tap('mark_paid', {'id': 2}));
      await tester.pump(const Duration(milliseconds: 10));
      final e = await refused(run(b, tap('mark_paid', {'id': 2})));
      expect(e.code, 'busy');
      final other = run(b, tap('mark_paid', {'id': 3}));  // a different tap is not blocked
      gate.complete(http.Response(jsonEncode({'rowsAffected': 1}), 200));
      expect((await first as Map)['done'], true);
      expect((await other as Map)['done'], true);
      expect(server.posts, hasLength(2));
    });

    testWidgets('a loop in a page is stopped after a burst, and allowed again a minute later', (tester) async {
      await mount(tester);
      final b = bridge();
      for (var i = 0; i < maxMutationsPerMinute; i++) {
        await run(b, tap('mark_paid', {'id': i}));
      }
      final e = await refused(run(b, tap('mark_paid', {'id': 999})));
      expect(e.code, 'too_many_requests');
      expect(server.posts, hasLength(maxMutationsPerMinute));
      now = now.add(const Duration(seconds: 61));
      expect((await run(b, tap('mark_paid', {'id': 999})) as Map)['done'], true);
    });
  });

  group('a lost answer is not "not saved"', () {
    testWidgets('the outcome is unknown, and an identical retry carries the same key', (tester) async {
      await mount(tester);
      var calls = 0;
      server.onMutation = (_) {
        calls++;
        if (calls == 1) throw const SocketException('connection reset');
        return http.Response(jsonEncode({'rowsAffected': 1, 'replayed': true}), 200);
      };
      final b = bridge();
      final e = await refused(run(b, tap('mark_paid', {'id': 2})));
      expect(e.code, 'unknown_outcome');
      expect(e.key, SurfacesText.mutateUnknownOutcome);
      final retry = await run(b, tap('mark_paid', {'id': 2})) as Map;
      expect(retry['replayed'], true);
      expect(server.keys, hasLength(2));
      expect(server.keys.first, server.keys.last, reason: 'the server can then answer with the first result');
      // Done now: a later tap of the same button is a new action with a new key.
      await run(b, tap('mark_paid', {'id': 2}));
      expect(server.keys.last, isNot(server.keys.first));
    });

    testWidgets('a different request does not reuse that key', (tester) async {
      await mount(tester);
      server.onMutation = (r) => server.posts.length == 1 ? throw const SocketException('x') : http.Response('{"rowsAffected":1}', 200);
      final b = bridge();
      await refused(run(b, tap('mark_paid', {'id': 2})));
      await run(b, tap('mark_paid', {'id': 3}));
      expect(server.keys.first, isNot(server.keys.last));
    });

    testWidgets('after ten minutes the key is not carried over any more', (tester) async {
      await mount(tester);
      server.onMutation = (r) => server.posts.length == 1 ? throw const SocketException('x') : http.Response('{"rowsAffected":1}', 200);
      final b = bridge();
      await refused(run(b, tap('mark_paid', {'id': 2})));
      now = now.add(mutationKeyKeep + const Duration(seconds: 1));
      await run(b, tap('mark_paid', {'id': 2}));
      expect(server.keys.first, isNot(server.keys.last));
    });

    testWidgets('the server saying it cannot tell (an earlier attempt may have written) keeps the key too', (tester) async {
      await mount(tester);
      var calls = 0;
      server.onMutation = (_) => ++calls == 1
          ? failure(409, 'an earlier attempt may or may not have changed the data', 'outcome_unknown')
          : http.Response('{"rowsAffected":1}', 200);
      final b = bridge();
      expect((await refused(run(b, tap('mark_paid', {'id': 2})))).code, 'unknown_outcome');
      await run(b, tap('mark_paid', {'id': 2}));
      expect(server.keys.first, server.keys.last);
    });

    testWidgets('a server error keeps the key, because the server may have written before failing', (tester) async {
      await mount(tester);
      var calls = 0;
      server.onMutation = (_) => ++calls == 1 ? failure(500, 'boom') : http.Response('{"rowsAffected":1}', 200);
      final b = bridge();
      expect((await refused(run(b, tap('mark_paid', {'id': 2})))).code, 'server_error');
      await run(b, tap('mark_paid', {'id': 2}));
      expect(server.keys.first, server.keys.last);
    });
  });

  group('what the server refuses', () {
    Future<HostError> after(WidgetTester tester, http.Response answer) async {
      await mount(tester);
      server.onMutation = (_) => answer;
      return refused(run(bridge(), tap('mark_paid', {'id': 2})));
    }

    testWidgets('a plain 409 is a stale revision, which makes the host look for an update', (tester) async {
      final e = await after(tester, failure(409, 'stale revision'));
      expect(e.code, 'stale_revision');
      expect(e.key, SurfacesText.hostStaleRevision);
    });

    testWidgets('a key already used for another request is not a stale revision', (tester) async {
      final e = await after(tester, failure(409, 'this request key was already used', 'request_key_reused'));
      expect(e.code, 'conflict');
    });

    testWidgets('arguments or data the server will not accept are reported in its own words', (tester) async {
      final e = await after(tester, failure(400, 'mutation mark_paid: UNIQUE constraint failed: bills.id'));
      expect((e.code, e.message, e.key), ('rejected', 'mutation mark_paid: UNIQUE constraint failed: bills.id', null));
    });

    testWidgets('an older plugin, which has no such route', (tester) async {
      expect((await after(tester, failure(404, 'Not Found'))).code, 'server_old');
    });

    testWidgets('an app that is gone', (tester) async {
      expect((await after(tester, failure(404, 'app is not published'))).code, 'not_found');
    });

    testWidgets('a rejected token', (tester) async {
      expect((await after(tester, failure(401, 'bad token'))).code, 'unauthorized');
    });

    testWidgets('a refusal drops the key, so the next tap is a new action', (tester) async {
      await mount(tester);
      var calls = 0;
      server.onMutation = (_) => ++calls == 1 ? failure(400, 'refused') : http.Response('{"rowsAffected":1}', 200);
      final b = bridge();
      await refused(run(b, tap('mark_paid', {'id': 2})));
      await run(b, tap('mark_paid', {'id': 2}));
      expect(server.keys.first, isNot(server.keys.last));
    });
  });
}
