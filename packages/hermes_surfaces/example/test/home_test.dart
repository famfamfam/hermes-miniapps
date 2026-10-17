import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_example/main.dart';

class _Api extends SurfacesApi {
  _Api(super.config);
  List<PreviewSummary> waiting = [
    PreviewSummary(appId: 'utilities', title: 'Test preview', draftRev: 5, buildId: 'build_test', baseRevision: 2, isNew: false),
  ];
  int healthCalls = 0;
  int previewReads = 0;

  @override
  Future<Map<String, dynamic>> hello({required int sdkMajor, required String timezone}) async => {'compatible': true};
  @override
  Future<List<AppSummary>> listApps() async => [AppSummary('utilities', 'Published app', null, 3)];
  @override
  Future<Map<String, dynamic>> health() async {
    healthCalls++;
    return {'reviews': true, 'approverPaired': true};
  }

  @override
  Future<List<PreviewSummary>> previews() async {
    previewReads++;
    return waiting;
  }
}

class _BrokenPreviewApi extends PreviewApi {
  _BrokenPreviewApi(super.config, this.reason);
  final String reason;
  @override
  Future<AppManifest> manifest(String appId) async => throw ManifestException(reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final reason in ['preview manifest is missing preview metadata', 'invalid preview buildId']) {
    testWidgets('first preview manifest rejection is handled: $reason', (tester) async {
      final dir = Directory.systemTemp.createTempSync('ms_home_manifest_test');
      final config = ServerConfig(baseUri: Uri.parse('http://localhost:8787'), token: 'test', deviceId: 'test');
      File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({
        'url': config.baseUri.toString(), 'token': config.token, 'deviceId': config.deviceId,
      }));
      File('${dir.path}/approver_ed25519.key').writeAsStringSync(base64Encode(List.filled(32, 0)));
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (_) async => dir.path);
      final api = _Api(config);
      final host = SurfacesHost(api: api, bundles: BundleStore(dir), snapshots: SnapshotCache(dir));
      final broken = _BrokenPreviewApi(config.forPreview(), reason);
      final previewHost = SurfacesHost(api: broken,
          bundles: BundleStore(Directory('${dir.path}/preview')), snapshots: SnapshotCache(dir));
      Future<void> settle(int healthCalls) async {
        for (var i = 0; i < 80 && api.healthCalls < healthCalls; i++) {
          await tester.pump(); // Build AppsModule after the native settings load completes.
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      try {
        await tester.runAsync(() async {
          await tester.pumpWidget(MaterialApp(home: Home(
            hostBuilder: (_) async => host, previewHostBuilder: (_) async => previewHost,
          )));
          await settle(1);
        });
        await tester.pump();
        await tester.runAsync(() async {
          await tester.tap(find.text('Test preview'));
          await settle(2);
        });
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('Manifest rejected: $reason'), findsOneWidget);
        expect(find.byType(SurfaceView), findsNothing);
        expect(tester.widget<ListTile>(find.ancestor(of: find.text('Test preview'),
            matching: find.byType(ListTile))).onTap, isNotNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        api.close();
        broken.close();
        messenger.setMockMethodCallHandler(paths, null);
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Windows may still hold a handle while the final connection read completes.
        }
      }
    });
  }

  // The periodic 5 s timer would hide the defect this guards against, so the test never lets it
  // fire: it waits only for the connection round trip to finish, in real time, well under 5 s.
  testWidgets('a connection refresh drops a decided preview at once, not on the next timer tick', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ms_home_test');
    final config = ServerConfig(baseUri: Uri.parse('http://localhost:8787'), token: 'test', deviceId: 'test');
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({
      'url': config.baseUri.toString(), 'token': config.token, 'deviceId': config.deviceId,
    }));
    File('${dir.path}/approver_ed25519.key').writeAsStringSync(base64Encode(List.filled(32, 0)));
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, (_) async => dir.path);
    final api = _Api(config);
    final host = SurfacesHost(api: api, bundles: BundleStore(dir), snapshots: SnapshotCache(dir));

    // File and channel I/O only progresses in real time, so everything that starts it runs inside
    // runAsync. Waits for the connection's health call, then a short grace for the steps after it.
    Future<void> settle(int healthCalls) async {
      for (var i = 0; i < 80 && api.healthCalls < healthCalls; i++) {
        await tester.pump(); // Build AppsModule after the native settings load completes.
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(home: Home(hostBuilder: (_) async => host)));
        await settle(1);
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('Test preview'), findsOneWidget);
      expect(api.previewReads, 1, reason: 'the list is read as part of the connection, not by the timer');

      api.waiting = [];
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Refresh'));
        await settle(2);
      });
      await tester.pump();
      await tester.pump();
      expect(api.previewReads, 2);
      expect(find.text('Test preview'), findsNothing);
      expect(find.text('Waiting for your decision'), findsNothing);
      expect(find.text('Published app'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      api.close();
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold a handle on a log file; the OS cleans the temp directory later.
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    }
  });
}
