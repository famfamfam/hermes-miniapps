import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoLocalizations, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:http/http.dart' as http;

typedef Responder = FutureOr<http.Response> Function(http.Request request, SurfacesConnection connection);

class FakeClient extends http.BaseClient {
  FakeClient(this.connection, this.respond);
  final SurfacesConnection connection;
  final Responder respond;
  final List<http.Request> requests = [];
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    requests.add(req);
    // Deliberately permissive after close. Apps must enforce its own closed/binding gate.
    final response = await respond(req, connection);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }

  @override
  void close() {
    closes++;
  }
}

class FakeBridge extends HostBridge {
  FakeBridge(this.root, SurfacesConnection? connection, this.respond) : activeConnection = ValueNotifier(connection);
  final Directory root;
  final Responder respond;
  final List<FakeClient> clients = [];
  int supportReads = 0;
  int keyReads = 0;
  int chatCalls = 0;
  ApproverKey? key;
  Future<ApproverKey?> Function()? readKey;

  /// What the host would offer pages for files and for messaging Hermes (null = it cannot).
  HostFileActions? files;
  SendToHermes? send;

  @override
  HostFileActions? get fileActions => files;
  @override
  SendToHermes? get sendToHermes => send;

  @override
  final ValueNotifier<SurfacesConnection?> activeConnection;
  @override
  Future<Directory> applicationSupportDirectory() async {
    supportReads++;
    return root;
  }

  @override
  Future<ApproverKey?> loadApproverKey() async {
    keyReads++;
    return readKey == null ? key : await readKey!();
  }

  @override
  http.Client createSurfacesClient(SurfacesConnection connection) {
    final client = FakeClient(connection, respond);
    clients.add(client);
    return client;
  }

  @override
  Future<void> openChat() async {
    chatCalls++;
  }

  Iterable<http.Request> get requests => clients.expand((client) => client.requests);
  int count(String path) => requests.where((r) => r.url.path.endsWith(path)).length;
}

SurfacesConnection connection({
  String profile = 'profile_a',
  String generation = 'generation_1',
  String token = 'synthetic_token',
}) => SurfacesConnection(
  config: ServerConfig(
    baseUri: Uri.parse('https://synthetic.invalid/tenant'),
    token: token,
    deviceId: 'synthetic_device',
    connectionId: 'synthetic_connection',
    profileId: profile,
    credentialGeneration: generation,
  ),
);

http.Response jsonResponse(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status, headers: {'content-type': 'application/json'});

class SyntheticServer {
  SyntheticServer({this.reviews = false});
  final SyntheticBundle bundle = SyntheticBundle();
  bool reviews;
  bool paired = true;
  String title = 'Synthetic app';
  String previewTitle = 'Synthetic preview';
  String listedBuild = 'build_listed';
  String installedBuild = 'build_displayed';
  final List<http.Request> decisions = [];
  int revision = 3;

  /// The server can delete apps (an older plugin does not announce it).
  bool appDelete = false;

  /// Set by a successful deletion: the app is gone from the list.
  bool deleted = false;
  int deleteStatus = 200;
  final List<http.Request> deletions = [];

  FutureOr<http.Response> respond(http.Request req, SurfacesConnection c) {
    final path = req.url.path.substring('/tenant$apiPrefix'.length);
    if (path == '/devices/hello') return jsonResponse({'compatible': true});
    if (path == '/apps') {
      return jsonResponse({
        'apps': [
          if (!deleted) {'appId': 'utilities', 'title': title, 'revision': revision},
        ],
      });
    }
    if (path == '/health') {
      return jsonResponse({'reviews': reviews, 'approverPaired': paired, if (appDelete) 'appDelete': true});
    }
    if (path == '/apps/utilities/delete/challenge') {
      deletions.add(req);
      const nonce = 'synthetic_delete_nonce';
      return jsonResponse({
        'appId': 'utilities',
        'revision': revision,
        'bundleId': bundle.id,
        'nonce': nonce,
        'message': canonicalDeleteMessage(appId: 'utilities', revision: revision, bundleId: bundle.id, nonce: nonce),
      });
    }
    if (path == '/apps/utilities/delete') {
      deletions.add(req);
      if (deleteStatus != 200) return jsonResponse({'error': 'refused by the synthetic server'}, deleteStatus);
      deleted = true;
      return jsonResponse({'status': 'deleted', 'appId': 'utilities'});
    }
    if (path == '/previews') {
      return jsonResponse({
        'previews': reviews
            ? [
                {
                  'appId': 'utilities',
                  'title': previewTitle,
                  'draftRev': 4,
                  'buildId': listedBuild,
                  'baseRevision': 3,
                  'isNew': false,
                },
              ]
            : [],
      });
    }
    if (path.endsWith('/bundles/${Uri.encodeComponent(bundle.id)}') || path.contains('/bundles/')) {
      return http.Response.bytes(bundle.zip, 200);
    }
    if (path == '/apps/utilities' || path == '/previews/utilities') {
      return jsonResponse(bundle.manifest(preview: path.startsWith('/previews'), build: installedBuild));
    }
    if (path == '/previews/utilities/challenge') {
      decisions.add(req);
      const nonce = 'synthetic_nonce';
      return jsonResponse({
        'appId': 'utilities',
        'buildId': installedBuild,
        'draftRev': 4,
        'bundleId': bundle.id,
        'baseRevision': 3,
        'nonce': nonce,
        'message': canonicalApprovalMessage(
          appId: 'utilities',
          buildId: installedBuild,
          draftRev: 4,
          bundleId: bundle.id,
          baseRevision: 3,
          nonce: nonce,
        ),
      });
    }
    if (path == '/previews/utilities/approve') {
      decisions.add(req);
      return jsonResponse({'revision': 5});
    }
    if (path == '/previews/utilities/reject') {
      decisions.add(req);
      return jsonResponse({});
    }
    throw StateError('Unexpected synthetic API operation');
  }
}

/// Minimal stored ZIP generated only from synthetic data, without extra SDK dependencies.
class SyntheticBundle {
  SyntheticBundle() {
    final html = Uint8List.fromList(utf8.encode('<!doctype html><title>Synthetic</title>'));
    final metadata = {
      'format': 1,
      'sdkMajor': 1,
      'entrypoint': 'index.html',
      'capabilities': <String>[],
      'files': [
        {'path': 'index.html', 'size': html.length, 'sha256': digestBytes(html).substring(7)},
      ],
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(metadata)));
    id = digestBytes(bytes);
    zip = _zip({'bundle.json': bytes, 'index.html': html});
    verified = verifyBundle(zip, expectedId: id);
  }
  late final String id;
  late final Uint8List zip;
  late final VerifiedBundle verified;

  Map<String, dynamic> manifest({bool preview = false, String build = 'build_displayed'}) => {
    'appId': 'utilities',
    'title': preview ? 'Synthetic preview installed' : 'Synthetic app installed',
    'revision': preview ? 4 : 3,
    'epoch': 'synthetic_epoch',
    'bundle': {
      'bundleId': id,
      'size': zip.length,
      'format': 1,
      'sdkMajor': 1,
      'capabilities': <String>[],
      'contractHash': 'synthetic_contract',
    },
    if (preview) 'preview': {'buildId': build, 'baseRevision': 3},
  };

  Future<InstalledApp> install(Directory root, {String title = 'Cached synthetic app', bool preview = false}) =>
      BundleStore(root).install(
        'utilities',
        verified,
        title: title,
        revision: preview ? 4 : 3,
        contractHash: 'synthetic_contract',
        epoch: 'synthetic_epoch',
        preview: preview ? PreviewIdentity(buildId: 'build_displayed', baseRevision: 3) : null,
      );
}

Uint8List _zip(Map<String, Uint8List> files) {
  final local = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder out, int n) => out.add((ByteData(2)..setUint16(0, n, Endian.little)).buffer.asUint8List());
  void u32(BytesBuilder out, int n) => out.add((ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List());
  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final data = entry.value;
    final crc = _crc32(data);
    final offset = local.length;
    u32(local, 0x04034b50);
    for (final n in [20, 0, 0, 0, 0]) {
      u16(local, n);
    }
    for (final n in [crc, data.length, data.length]) {
      u32(local, n);
    }
    u16(local, name.length);
    u16(local, 0);
    local.add(name);
    local.add(data);
    u32(central, 0x02014b50);
    for (final n in [20, 20, 0, 0, 0, 0]) {
      u16(central, n);
    }
    for (final n in [crc, data.length, data.length]) {
      u32(central, n);
    }
    for (final n in [name.length, 0, 0, 0, 0]) {
      u16(central, n);
    }
    u32(central, 0);
    u32(central, offset);
    central.add(name);
  }
  final end = BytesBuilder();
  u32(end, 0x06054b50);
  u16(end, 0);
  u16(end, 0);
  u16(end, files.length);
  u16(end, files.length);
  u32(end, central.length);
  u32(end, local.length);
  u16(end, 0);
  return Uint8List.fromList([...local.takeBytes(), ...central.takeBytes(), ...end.takeBytes()]);
}

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

class FakePage extends StatefulWidget {
  const FakePage({super.key, required this.request, this.onDispose});
  final SurfacePageRequest request;
  final VoidCallback? onDispose;
  @override
  State<FakePage> createState() => _FakePageState();
}

class _FakePageState extends State<FakePage> {
  @override
  void dispose() {
    widget.onDispose?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Page ${widget.request.title}')),
    body: const Text('Synthetic page renderer'),
  );
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
  }
  fail('Apps did not become idle');
}

Future<void> mount(
  WidgetTester tester,
  FakeBridge bridge, {
  SurfacePageBuilder? pageBuilder,
  HostFactory? hostFactory,
  HostFactory? previewHostFactory,
  bool embedded = false,
  bool autoSync = false,
  List<Widget> actions = const [],
}) async {
  await tester.pumpWidget(
    localizedApp(
      home: Scaffold(
        body: AppsModule(
          bridge: bridge,
          embedded: embedded,
          hostFactory: hostFactory,
          previewHostFactory: previewHostFactory,
          surfacePageBuilder: pageBuilder,
          autoSync: autoSync,
          appBarActions: actions,
        ),
      ),
    ),
  );
  await settle(tester);
}

Future<void> open(WidgetTester tester, String title) async {
  await tester.runAsync(() => tester.tap(find.text(title)));
  await tester.pump();
  // Real I/O and HTTP fakes complete in real time: poll for the end of the open instead of guessing a delay.
  for (var i = 0; i < 300 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50)); // Let the route transition finish too.
  }
  await tester.pumpAndSettle();
}

Directory scopeRoot(Directory root, SurfacesConnection c, {bool preview = false}) =>
    Directory('${root.path}/surfaces/${preview ? c.config.forPreview().scope : c.scope}');

/// Supplies the (English) Material strings for ANY language: the default delegates only support
/// en, which would otherwise make every Material widget fail under another test locale.
class _AnyLanguageMaterial extends LocalizationsDelegate<MaterialLocalizations> {
  const _AnyLanguageMaterial();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<MaterialLocalizations> load(Locale locale) => DefaultMaterialLocalizations.load(const Locale('en'));
  @override
  bool shouldReload(covariant LocalizationsDelegate<MaterialLocalizations> old) => false;
}

class _AnyLanguageCupertino extends LocalizationsDelegate<CupertinoLocalizations> {
  const _AnyLanguageCupertino();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<CupertinoLocalizations> load(Locale locale) => DefaultCupertinoLocalizations.load(const Locale('en'));
  @override
  bool shouldReload(covariant LocalizationsDelegate<CupertinoLocalizations> old) => false;
}

/// A MaterialApp whose resolved locale is [locale]. The existing assertions are Russian wording, so
/// Russian is the default; pass Locale('en') (or an unregistered one) to see the fallback language.
MaterialApp localizedApp({
  Locale locale = const Locale('ru'),
  Widget? home,
  GlobalKey<NavigatorState>? navigatorKey,
  List<NavigatorObserver> navigatorObservers = const [],
  TransitionBuilder? builder,
}) => MaterialApp(
  locale: locale,
  supportedLocales: [const Locale('en'), locale],
  localizationsDelegates: const [_AnyLanguageMaterial(), _AnyLanguageCupertino()],
  navigatorKey: navigatorKey,
  navigatorObservers: navigatorObservers,
  builder: builder,
  home: home,
);
