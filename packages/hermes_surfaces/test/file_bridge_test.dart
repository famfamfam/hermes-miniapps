// The host's answers to the file operations of the page bridge: what is asked of the server, what is put in front of
// the user first, and which stable codes the page gets back when something is refused.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'locale_support.dart';

const origin = 'https://utilities.abcd1234.surfaces.invalid';
const fileId = 'f_0123456789abcdef';
const otherId = 'f_fedcba9876543210';
final pdf = Uint8List.fromList(List.generate(300, (i) => i % 251));
final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);

Map<String, Object?> record(String id, String name, String mime, int size) => {
      'fileId': id,
      'name': name,
      'mime': mime,
      'size': size,
      'sha256': 'ab' * 32,
      'source': 'phone',
      'createdAt': '2026-10-17T10:00:00Z',
    };

class FakeActions extends HostFileActions {
  PickedFile? toPick;
  FileOfferResult result = FileOfferResult.saved;
  List<String>? lastAccept;
  int picks = 0;
  final offered = <({String name, String mime, Uint8List bytes})>[];

  @override
  Future<PickedFile?> pick(BuildContext context, {required List<String> accept}) async {
    picks++;
    lastAccept = accept;
    return toPick;
  }

  @override
  Future<FileOfferResult> offer(BuildContext context,
      {required String name, required String mime, required Uint8List bytes}) async {
    offered.add((name: name, mime: mime, bytes: bytes));
    return result;
  }
}

/// Remembers the length the request announced (a streamed body's Content-Length), which the mock client drops.
class _Spy extends http.BaseClient {
  _Spy(this.inner, this.onSend);
  final http.Client inner;
  final void Function(http.BaseRequest request) onSend;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    onSend(request);
    return inner.send(request);
  }
}

class Server {
  final requests = <http.Request>[];
  final uploads = <({String name, List<int> body})>[];
  int? lastContentLength;
  http.Response Function(http.Request)? override;

  late final http.Client client = _Spy(_mock, (r) => lastContentLength = r.contentLength);

  late final MockClient _mock = MockClient((request) async {
    requests.add(request);
    final custom = override;
    if (custom != null) return custom(request);
    final path = request.url.path;
    if (request.method == 'POST' && path.endsWith('/apps/utilities/files')) {
      uploads.add((
        name: Uri.decodeComponent(request.headers['X-File-Name'] ?? ''),
        body: request.bodyBytes,
      ));
      return http.Response(
          jsonEncode({...record(fileId, 'receipt.pdf', 'application/pdf', request.bodyBytes.length), 'duplicate': false}), 200);
    }
    if (request.method == 'GET' && path.endsWith('/apps/utilities/files')) {
      return http.Response(
          jsonEncode({
            'files': [
              record(fileId, 'receipt.pdf', 'application/pdf', pdf.length),
              record(otherId, 'photo.png', 'image/png', png.length),
            ]
          }),
          200);
    }
    if (request.method == 'GET' && path.endsWith('/files/$fileId')) {
      return http.Response.bytes(pdf, 200,
          headers: {'content-type': 'application/pdf', 'x-file-name': Uri.encodeComponent('Квитанция март.pdf')});
    }
    if (request.method == 'GET' && path.endsWith('/files/$otherId')) {
      return http.Response.bytes(png, 200, headers: {'content-type': 'image/png', 'x-file-name': 'photo.png'});
    }
    if (request.method == 'POST' && path.contains('/downloads/')) {
      return http.Response.bytes(pdf, 200, headers: {'content-type': 'application/pdf', 'x-file-name': 'gas.pdf'});
    }
    if (request.method == 'DELETE') return http.Response('{"deleted":true}', 200);
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

InstalledApp installed(Directory tmp, {String appId = 'utilities', int revision = 7}) => InstalledApp(
      appId: appId,
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

PickedFile picked(Uint8List bytes, String name) =>
    PickedFile(name: name, length: bytes.length, open: () => Stream.fromIterable([bytes.sublist(0, 100), bytes.sublist(100)]));

void main() {
  late Directory tmp;
  late Server server;
  late FakeActions actions;
  late BuildContext context;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('file_bridge');
    server = Server();
    actions = FakeActions();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  FileBridge bridge({
    HostFileActions? withActions,
    SendToHermes? send,
    bool preview = false,
    int imageCacheBytes = 12 * 1024 * 1024,
    bool noActions = false,
  }) =>
      FileBridge(
        actions: noActions ? null : (withActions ?? actions),
        sendToHermes: send,
        preview: preview,
        timezone: () => 'Europe/Moscow',
        imageCacheBytes: imageCacheBytes,
      );

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(localizedApp(
      locale: const Locale('en'),
      home: Scaffold(body: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })),
    ));
  }

  Future<Object?> run(FileBridge b, Object rpc, {Directory? dir, bool previewHost = false}) =>
      b.handle(req(rpc), host: makeHost(server, tmp, preview: previewHost), app: installed(dir ?? tmp), title: 'Коммуналка', context: context);

  Future<HostError> refused(Future<Object?> call) async {
    try {
      await call;
    } on HostError catch (e) {
      return e;
    }
    fail('expected a HostError');
  }

  group('pickFile', () {
    testWidgets('uploads what the user picked, byte for byte, and tells the page only what it needs', (tester) async {
      await mount(tester);
      actions.toPick = picked(pdf, 'Квитанция март.pdf');
      final out = await run(bridge(), {'op': 'pickFile', 'accept': ['application/pdf']}) as Map;
      expect(actions.lastAccept, ['application/pdf']);
      expect(server.uploads, hasLength(1));
      expect(server.uploads.single.name, 'Квитанция март.pdf');
      expect(server.lastContentLength, pdf.length, reason: 'the length is announced, so the server can refuse early');
      expect(server.uploads.single.body, pdf);
      expect(out['fileId'], fileId);
      expect(out['name'], 'receipt.pdf');
      expect(out.keys.toSet(), {'fileId', 'name', 'mime', 'size', 'createdAt', 'duplicate'});
      expect(server.requests.single.headers['Authorization'], 'Bearer tok');
    });

    testWidgets('a cancelled picker is null and sends nothing', (tester) async {
      await mount(tester);
      expect(await run(bridge(), {'op': 'pickFile'}), isNull);
      expect(server.requests, isEmpty);
    });

    testWidgets('a file over the limit is refused before a byte is read', (tester) async {
      await mount(tester);
      var opened = false;
      actions.toPick = PickedFile(name: 'big.pdf', length: maxUploadBytes + 1, open: () {
        opened = true;
        return const Stream.empty();
      });
      final e = await refused(run(bridge(), {'op': 'pickFile'}));
      expect(e.code, 'too_large');
      expect(opened, isFalse);
      expect(server.requests, isEmpty);
    });

    testWidgets('an empty file is refused', (tester) async {
      await mount(tester);
      actions.toPick = PickedFile(name: 'empty.pdf', length: 0, open: () => const Stream.empty());
      expect((await refused(run(bridge(), {'op': 'pickFile'}))).code, 'bad_file');
      expect(server.requests, isEmpty);
    });

    for (final c in <(String, int, String)>[
      ('too_large', 413, 'the file is larger than 20 MB'),
      ('server_full', 507, 'the server is out of disk space'),
      ('not_found', 404, 'unknown app'),
      ('unauthorized', 401, 'unauthorized'),
      ('stale_revision', 409, 'stale'),
      ('server_error', 500, 'boom'),
      ('bad_file', 400, 'files of this type are not accepted (.exe)'),
    ]) {
      testWidgets('the server\'s ${c.$2} reaches the page as ${c.$1}', (tester) async {
        await mount(tester);
        actions.toPick = picked(pdf, 'a.pdf');
        server.override = (_) => http.Response(jsonEncode({'error': c.$3}), c.$2);
        final e = await refused(run(bridge(), {'op': 'pickFile'}));
        expect(e.code, c.$1);
        if (c.$1 == 'bad_file') expect(e.message, c.$3, reason: 'the server\'s own words, for the page to show');
      });
    }

    testWidgets('a server that has no file routes (an older plugin) is told apart from a missing file', (tester) async {
      await mount(tester);
      actions.toPick = picked(pdf, 'a.pdf');
      server.override = (_) => http.Response(jsonEncode({'detail': 'Not Found'}), 404);
      final e = await refused(run(bridge(), {'op': 'pickFile'}));
      expect(e.code, 'unsupported');
      expect(e.key, SurfacesText.fileServerOld);
    });

    testWidgets('no connection reaches the page as offline', (tester) async {
      await mount(tester);
      actions.toPick = picked(pdf, 'a.pdf');
      server.override = (_) => throw const SocketException('down');
      expect((await refused(run(bridge(), {'op': 'pickFile'}))).code, 'offline');
    });
  });

  group('saveFile', () {
    testWidgets('a stored file is downloaded and offered, with a name that is only a name', (tester) async {
      await mount(tester);
      actions.result = FileOfferResult.shared;
      final out = await run(bridge(), {'op': 'saveFile', 'fileId': fileId}) as Map;
      expect(out, {'action': 'shared', 'name': 'Квитанция март.pdf'});
      expect(actions.offered.single.name, 'Квитанция март.pdf');
      expect(actions.offered.single.mime, 'application/pdf');
      expect(actions.offered.single.bytes, pdf);
      expect(server.requests.single.url.path, endsWith('/apps/utilities/files/$fileId'));
    });

    testWidgets('a locator goes to the server with the revision, the arguments and the zone, never a path', (tester) async {
      await mount(tester);
      await run(bridge(), {'op': 'saveFile', 'name': 'receipt_file', 'args': {'id': 42}});
      final r = server.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, endsWith('/apps/utilities/downloads/receipt_file'));
      expect(jsonDecode(r.body), {'revision': 7, 'timezone': 'Europe/Moscow', 'args': {'id': 42}});
      expect(actions.offered.single.name, 'gas.pdf');
    });

    testWidgets('a user who closes the sheet is not an error', (tester) async {
      await mount(tester);
      actions.result = FileOfferResult.cancelled;
      expect(await run(bridge(), {'op': 'saveFile', 'fileId': fileId}), {'action': 'cancelled', 'name': 'Квитанция март.pdf'});
    });

    testWidgets('a name the server sent with directories in it is reduced before it is offered', (tester) async {
      await mount(tester);
      server.override = (_) => http.Response.bytes(pdf, 200,
          headers: {'content-type': 'application/pdf', 'x-file-name': Uri.encodeComponent('../../etc/passwd')});
      await run(bridge(), {'op': 'saveFile', 'fileId': fileId});
      expect(actions.offered.single.name, 'passwd');
    });

    testWidgets('a stale revision asks the host to refresh the app', (tester) async {
      await mount(tester);
      server.override = (_) => http.Response('{"error":"stale revision"}', 409);
      expect((await refused(run(bridge(), {'op': 'saveFile', 'name': 'receipt_file'}))).code, 'stale_revision');
      expect(actions.offered, isEmpty);
    });
  });

  group('listFiles', () {
    testWidgets('lists the app\'s files, in the page\'s shape', (tester) async {
      await mount(tester);
      final out = await run(bridge(), {'op': 'listFiles'}) as Map;
      final files = (out['files'] as List).cast<Map>();
      expect(files.map((f) => f['fileId']), [fileId, otherId]);
      expect(files.first.keys.toSet(), {'fileId', 'name', 'mime', 'size', 'createdAt'});
    });
  });

  group('deleteFile', () {
    testWidgets('asks first, names the file, and deletes only on the user\'s yes', (tester) async {
      await mount(tester);
      final call = run(bridge(), {'op': 'deleteFile', 'fileId': fileId});
      await tester.pumpAndSettle();
      expect(find.text('Delete “receipt.pdf”?'), findsOneWidget);
      expect(server.requests.where((r) => r.method == 'DELETE'), isEmpty);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(await call, {'deleted': true});
      expect(server.requests.where((r) => r.method == 'DELETE').single.url.path, endsWith('/files/$fileId'));
    });

    testWidgets('Cancel deletes nothing', (tester) async {
      await mount(tester);
      final call = run(bridge(), {'op': 'deleteFile', 'fileId': fileId});
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await call, {'deleted': false});
      expect(server.requests.where((r) => r.method == 'DELETE'), isEmpty);
    });

    testWidgets('a file the server does not list is not_found, and no dialog opens', (tester) async {
      await mount(tester);
      final e = await refused(run(bridge(), {'op': 'deleteFile', 'fileId': 'f_aaaaaaaaaaaaaaaa'}));
      expect(e.code, 'not_found');
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('askHermes', () {
    testWidgets('shows the whole message, and sends exactly that text only after the user\'s yes', (tester) async {
      await mount(tester);
      final sent = <String>[];
      final call = run(bridge(send: (t) async {
        sent.add(t);
        return true;
      }), {'op': 'askHermes', 'prompt': 'Разбери квитанцию и внеси сумму', 'fileIds': [fileId]});
      await tester.pumpAndSettle();
      expect(find.text('Send to Hermes?'), findsOneWidget);
      final shown = tester.widget<SelectableText>(find.descendant(of: find.byKey(const ValueKey('ask-hermes-text')), matching: find.byType(SelectableText))).data!;
      expect(shown, startsWith('Разбери квитанцию и внеси сумму'));
      expect(shown, contains('app_id=utilities'));
      expect(shown, contains('file_id=$fileId'));
      expect(shown, contains('receipt.pdf'));
      expect(sent, isEmpty, reason: 'nothing leaves before the tap');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(await call, {'sent': true});
      expect(sent, [shown]);
    });

    testWidgets('Cancel sends nothing', (tester) async {
      await mount(tester);
      var sends = 0;
      final call = run(bridge(send: (_) async {
        sends++;
        return true;
      }), {'op': 'askHermes', 'prompt': 'hi'});
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await call, {'sent': false});
      expect(sends, 0);
    });

    testWidgets('a host that cannot message Hermes says so and shows nothing', (tester) async {
      await mount(tester);
      final e = await refused(run(bridge(), {'op': 'askHermes', 'prompt': 'hi'}));
      expect(e.code, 'unsupported');
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a file that is not the app\'s is refused before the user is asked', (tester) async {
      await mount(tester);
      final e = await refused(run(bridge(send: (_) async => true), {'op': 'askHermes', 'prompt': 'hi', 'fileIds': ['f_aaaaaaaaaaaaaaaa']}));
      expect(e.code, 'not_found');
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a chat that could not be started is reported', (tester) async {
      await mount(tester);
      final call = refused(run(bridge(send: (_) async => false), {'op': 'askHermes', 'prompt': 'hi'}));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect((await call).code, 'send_failed');
    });

    test('the footer lists each file and belongs to the host, not the page', () {
      final text = composeAsk('Посмотри файл',
          title: 'Коммуналка',
          appId: 'utilities',
          files: [
            StoredFile(fileId: fileId, name: 'a.pdf', mime: 'application/pdf', size: 2048, source: 'phone', createdAt: ''),
          ]);
      expect(text, startsWith('Посмотри файл\n\n'));
      expect(text, contains('app “Коммуналка” (app_id=utilities)'));
      expect(text, contains('• a.pdf · application/pdf · 2 KB · file_id=$fileId'));
      expect(composeAsk('x', title: 't', appId: 'a_b', files: const []), isNot(contains('file_id')));
    });
  });

  group('what is switched off', () {
    for (final rpc in <Map<String, Object?>>[
      {'op': 'pickFile'},
      {'op': 'listFiles'},
      {'op': 'deleteFile', 'fileId': fileId},
      {'op': 'saveFile', 'fileId': fileId},
      {'op': 'askHermes', 'prompt': 'hi'},
    ]) {
      testWidgets('${rpc['op']} in a preview does nothing at all', (tester) async {
        await mount(tester);
        actions.toPick = picked(pdf, 'a.pdf');
        final e = await refused(run(bridge(preview: true, send: (_) async => true), rpc, previewHost: true));
        expect(e.code, 'preview_blocked');
        expect(server.requests, isEmpty);
        expect(actions.picks, 0);
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('${rpc['op']} without the application\'s pickers says unsupported', (tester) async {
        await mount(tester);
        final e = await refused(run(bridge(noActions: true), rpc));
        expect(e.code, 'unsupported');
        expect(server.requests.where((r) => r.method != 'GET'), isEmpty);
      });
    }
  });

  group('pictures for the page', () {
    testWidgets('an image of the app\'s files is served, once, then from memory', (tester) async {
      final b = bridge();
      final host = makeHost(server, tmp);
      final first = await b.picture(host, installed(tmp), otherId);
      expect(first!.mime, 'image/png');
      expect(first.bytes, png);
      await b.picture(host, installed(tmp), otherId);
      expect(server.requests, hasLength(1));
    });

    testWidgets('a file that is not an image is not served as one', (tester) async {
      expect(await bridge().picture(makeHost(server, tmp), installed(tmp), fileId), isNull);
    });

    testWidgets('only ids the server issues are looked up', (tester) async {
      final b = bridge();
      for (final id in ['../../x', 'f_xyz', 'http://evil.example/a.png', '']) {
        expect(await b.picture(makeHost(server, tmp), installed(tmp), id), isNull, reason: id);
      }
      expect(server.requests, isEmpty);
    });

    testWidgets('a preview serves none', (tester) async {
      expect(await bridge(preview: true).picture(makeHost(server, tmp, preview: true), installed(tmp), otherId), isNull);
      expect(server.requests, isEmpty);
    });

    testWidgets('a server that is gone or says no gives no picture, not an error', (tester) async {
      server.override = (_) => throw const SocketException('down');
      expect(await bridge().picture(makeHost(server, tmp), installed(tmp), otherId), isNull);
      server.override = (_) => http.Response('{"error":"unknown file"}', 404);
      expect(await bridge().picture(makeHost(server, tmp), installed(tmp), otherId), isNull);
    });

    testWidgets('the memory is bounded, and a deleted file is not served from it', (tester) async {
      final b = bridge(imageCacheBytes: png.length + 2);
      final host = makeHost(server, tmp);
      await b.picture(host, installed(tmp), otherId);
      await b.picture(host, installed(tmp), otherId);
      expect(server.requests, hasLength(1));
      b.forgetFile('utilities', otherId);
      await b.picture(host, installed(tmp), otherId);
      expect(server.requests, hasLength(2), reason: 'forgotten, so fetched again');
      // an entry bigger than the whole memory is served but never kept
      final tiny = bridge(imageCacheBytes: 2);
      await tiny.picture(host, installed(tmp), otherId);
      await tiny.picture(host, installed(tmp), otherId);
      expect(server.requests, hasLength(4));
    });

    testWidgets('one app\'s picture is not another app\'s', (tester) async {
      final b = bridge();
      final host = makeHost(server, tmp);
      await b.picture(host, installed(tmp), otherId);
      server.override = (_) => http.Response('{"error":"unknown file"}', 404);
      expect(await b.picture(host, installed(tmp, appId: 'other_app'), otherId), isNull);
    });
  });
}
