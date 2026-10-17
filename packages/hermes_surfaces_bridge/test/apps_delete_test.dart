import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:hermes_surfaces_bridge/src/bound_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

/// Deleting an app from the Apps list: the paired device signs, the server moves the app to its trash, and
/// this phone drops its downloaded copy. A copy the server no longer has is dropped on an online refresh.

const menuKey = ValueKey('app-menu-utilities');

class Env {
  Env(this.server, this.bridge, this.conn);
  final SyntheticServer server;
  final FakeBridge bridge;
  final SurfacesConnection conn;
  Directory get appDir => Directory('${scopeRoot(bridge.root, conn).path}/apps/utilities');
}

Future<Env> prepare(
  WidgetTester tester, {
  bool appDelete = true,
  bool withKey = true,
  Responder? respond,
  bool installed = true,
}) async {
  final server = SyntheticServer(reviews: true)..appDelete = appDelete;
  final conn = connection();
  final root = Directory.systemTemp.createTempSync('hermes_bridge_delete_');
  final bridge = FakeBridge(root, conn, respond ?? server.respond);
  if (withKey) bridge.key = await ApproverKey.fromSeed(Uint8List(32));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    });
    bridge.activeConnection.dispose();
  });
  if (installed) {
    await tester.runAsync(() => server.bundle.install(scopeRoot(root, conn), title: 'Cached synthetic app'));
  }
  return Env(server, bridge, conn);
}

/// Menu, "Delete app", then the confirmation.
Future<void> deleteViaMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(menuKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Удалить приложение'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('apps-delete-dialog')), findsOneWidget);
  await confirmDeletion(tester);
}

/// The confirm button, then the closing dialog, then the real I/O (files, fake HTTP) until Apps is idle again.
Future<void> confirmDeletion(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('apps-delete-confirm')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500)); // the dialog closes; the deletion starts
  await settle(tester);
  await tester.pump(const Duration(milliseconds: 500)); // the snack bar and the list settle
}

void main() {
  testWidgets('the menu is there while online and offers one action', (tester) async {
    final env = await prepare(tester);
    await mount(tester, env.bridge);
    expect(find.byKey(menuKey), findsOneWidget);
    await tester.tap(find.byKey(menuKey));
    await tester.pumpAndSettle();
    expect(find.text('Удалить приложение'), findsOneWidget);
  });

  testWidgets('offline there is no menu: deleting needs the server', (tester) async {
    final env = await prepare(tester, respond: (_, _) => throw http.ClientException('down'));
    await mount(tester, env.bridge);
    expect(find.text('Cached synthetic app'), findsOneWidget, reason: 'the downloaded copy still shows');
    expect(find.byKey(menuKey), findsNothing);
  });

  testWidgets('delete asks first, then signs what the server asked, drops the copy and the row', (tester) async {
    final env = await prepare(tester);
    await mount(tester, env.bridge);
    expect(env.appDir.existsSync(), isTrue);

    await tester.tap(find.byKey(menuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить приложение'));
    await tester.pumpAndSettle();
    expect(find.text('Удалить «Synthetic app»?'), findsOneWidget);
    expect(find.textContaining('в корзину на сервере на 30 дней'), findsOneWidget);
    expect(env.server.deletions, isEmpty, reason: 'nothing is sent before the user confirms');

    await confirmDeletion(tester);

    expect(env.server.deletions.map((r) => r.url.path.split('/').last), ['challenge', 'delete']);
    final posted = jsonDecode(env.server.deletions.last.body) as Map<String, dynamic>;
    final message = canonicalDeleteMessage(
      appId: 'utilities',
      revision: 3,
      bundleId: env.server.bundle.id,
      nonce: 'synthetic_delete_nonce',
    );
    expect(posted['nonce'], 'synthetic_delete_nonce');
    expect(posted['signature'], await env.bridge.key!.sign(message));
    expect(find.text('Synthetic app'), findsNothing);
    expect(find.text('Удалено «Synthetic app»'), findsOneWidget);
    expect(env.appDir.existsSync(), isFalse, reason: 'the downloaded copy goes with it');
  });

  testWidgets('cancelling sends nothing and keeps the app', (tester) async {
    final env = await prepare(tester);
    await mount(tester, env.bridge);
    await tester.tap(find.byKey(menuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить приложение'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(env.server.deletions, isEmpty);
    expect(find.text('Synthetic app'), findsOneWidget);
    expect(env.appDir.existsSync(), isTrue);
  });

  testWidgets('a refusal from the server leaves the list and the copy alone and says why', (tester) async {
    final env = await prepare(tester);
    env.server.deleteStatus = 409;
    await mount(tester, env.bridge);
    await deleteViaMenu(tester);
    expect(find.textContaining('Сервер не удалил приложение'), findsOneWidget);
    expect(find.text('Synthetic app'), findsOneWidget);
    expect(env.appDir.existsSync(), isTrue);
  });

  testWidgets('an app that changed after the list was read is not signed away', (tester) async {
    final env = await prepare(tester);
    await mount(tester, env.bridge);
    env.server.revision = 4; // published again while the list was on screen
    await deleteViaMenu(tester);
    expect(find.textContaining('Приложение на сервере изменилось'), findsOneWidget);
    expect(env.server.deletions.map((r) => r.url.path.split('/').last), ['challenge'], reason: 'nothing was signed');
    expect(find.text('Synthetic app'), findsOneWidget);
  });

  testWidgets('a binding switch while the challenge is on the wire sends no deletion', (tester) async {
    late Env env;
    final other = connection(token: 'another_token', generation: 'generation_2');
    env = await prepare(
      tester,
      respond: (req, c) {
        final answer = env.server.respond(req, c);
        if (req.url.path.endsWith('/delete/challenge')) env.bridge.activeConnection.value = other;
        return answer;
      },
    );
    await mount(tester, env.bridge);
    await tester.tap(find.byKey(menuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить приложение'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('apps-delete-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      env.server.deletions.map((r) => r.url.path.split('/').last),
      ['challenge'],
      reason: 'the signature must not leave for a connection the user has left',
    );
    expect(env.server.deleted, isFalse);
  });

  test('the binding gate covers both deletion calls: an inactive binding sends neither', () async {
    final seen = <http.Request>[];
    var active = true;
    final api = bindApi(
      SurfacesApi(
        connection().config,
        client: MockClient((req) async {
          seen.add(req);
          return jsonResponse({'status': 'deleted'});
        }),
      ),
      () => active,
    );
    await api.deleteApp('utilities', nonce: 'n', signature: 's'); // while active it goes through
    expect(seen, hasLength(1));
    active = false;
    await expectLater(api.deleteApp('utilities', nonce: 'n', signature: 's'), throwsA(isA<OfflineException>()));
    await expectLater(api.deleteChallenge('utilities'), throwsA(isA<OfflineException>()));
    expect(seen, hasLength(1), reason: 'nothing was sent once the binding was gone');
  });

  testWidgets('an older server that cannot delete says so and is not asked', (tester) async {
    final env = await prepare(tester, appDelete: false);
    await mount(tester, env.bridge);
    await tester.tap(find.byKey(menuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить приложение'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Этот сервер ещё не умеет удалять'), findsOneWidget);
    expect(find.byKey(const ValueKey('apps-delete-dialog')), findsNothing);
    expect(env.server.deletions, isEmpty);
  });

  testWidgets('without this phone as the paired device the reason is shown instead of a dialog', (tester) async {
    final env = await prepare(tester, withKey: false);
    await mount(tester, env.bridge);
    await tester.tap(find.byKey(menuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить приложение'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('apps-delete-dialog')), findsNothing);
    expect(find.textContaining('Подтверждение отключено'), findsWidgets, reason: 'the banner and the snack bar');
    expect(env.server.deletions, isEmpty);
  });

  testWidgets('a copy the server no longer has is dropped on an online refresh, never while offline', (tester) async {
    final env = await prepare(tester);
    env.server.deleted = true; // deleted elsewhere: this phone still holds the download
    await mount(tester, env.bridge);
    expect(find.text('Synthetic app'), findsNothing);
    expect(env.appDir.existsSync(), isFalse);

    final offline = await prepare(tester, respond: (_, _) => throw http.ClientException('down'));
    await mount(tester, offline.bridge);
    expect(find.text('Cached synthetic app'), findsOneWidget);
    expect(offline.appDir.existsSync(), isTrue, reason: 'offline proves nothing about the server');
  });
}
