import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/src/bundle_store.dart';
import 'package:hermes_surfaces/src/bundle_verify.dart';
import 'package:hermes_surfaces/src/preview.dart';

VerifiedBundle bundleOf(String content) {
  final bytes = Uint8List.fromList(utf8.encode(content));
  final manifest = <String, dynamic>{
    'format': 1,
    'sdkMajor': 1,
    'capabilities': <String>[],
    'entrypoint': 'index.html',
    'files': [
      {'path': 'index.html', 'sha256': digestBytes(bytes).substring(7), 'size': bytes.length},
    ],
  };
  return VerifiedBundle(digestBytes(utf8.encode(jsonEncode(manifest))), manifest, {'index.html': bytes});
}

Future<InstalledApp> install(
  BundleStore store,
  VerifiedBundle bundle, {
  String appId = 'utilities',
  int revision = 1,
  PreviewIdentity? preview,
  Future<void> Function()? beforeSwitch,
}) => store.install(
  appId,
  bundle,
  title: 'version $revision',
  revision: revision,
  contractHash: 'contract $revision',
  epoch: 'epoch $revision',
  preview: preview,
  onBeforeSwitch: beforeSwitch,
);

void main() {
  late Directory tmp;
  late BundleStore store;
  late BundleStore otherStore;
  final a = bundleOf('A');
  final b = bundleOf('B');
  final c = bundleOf('C');
  final d = bundleOf('D');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ms_bundle_store_test');
    store = BundleStore(Directory('${tmp.path}/cache'));
    otherStore = BundleStore(Directory('${store.root.path}/.'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File pointer() => File('${store.root.path}/apps/utilities/installed.json');
  Directory version(VerifiedBundle bundle, {String appId = 'utilities', BundleStore? inStore}) =>
      Directory('${(inStore ?? store).root.path}/apps/$appId/versions/${bundle.bundleId.substring(7)}');
  void expectNoTemporaryFiles() {
    final paths = store.root.listSync(recursive: true).map((e) => e.path.replaceAll('\\', '/'));
    expect(paths.where((path) => path.contains('/staging') || path.endsWith('.tmp')), isEmpty);
  }

  test('malformed pointers recover to null, including asynchronous field and time failures', () async {
    final installed = await install(store, a);
    final original = await pointer().readAsString();
    final json = jsonDecode(original) as Map<String, dynamic>;
    final malformed = <String>['{', '[]', 'null', '"not an object"'];
    for (final field in ['bundleId', 'revision', 'contractHash', 'epoch', 'installedAt']) {
      malformed.add(jsonEncode(Map<String, dynamic>.from(json)..remove(field)));
    }
    for (final entry in <String, Object?>{
      'bundleId': 123,
      'revision': '1',
      'contractHash': 123,
      'epoch': 123,
      'installedAt': 'not a time',
      'title': 123,
    }.entries) {
      malformed.add(jsonEncode({...json, entry.key: entry.value}));
    }
    malformed.add(jsonEncode({...json, 'installedAt': 123}));
    for (final raw in malformed) {
      await pointer().writeAsString(raw);
      expect(await otherStore.current('utilities'), isNull, reason: raw);
    }
    await pointer().delete();
    expect(await store.current('utilities'), isNull);
    await pointer().writeAsString(original);
    expect((await otherStore.current('utilities'))!.bundleId, installed.bundleId);
    expect(await store.read(installed, 'index.html'), isNotNull);
  });

  test('missing and malformed on-disk manifests recover to null rather than async exceptions', () async {
    final installed = await install(store, a);
    final manifest = File('${installed.dir.path}/bundle.json');
    final original = await manifest.readAsString();
    for (final raw in <String>[
      '{',
      '[]',
      'null',
      '{}',
      jsonEncode({...a.manifest, 'files': null}),
      jsonEncode({...a.manifest, 'files': 'not a list'}),
      jsonEncode({
        ...a.manifest,
        'files': [123],
      }),
      jsonEncode({
        ...a.manifest,
        'files': [
          {'path': 123},
        ],
      }),
      jsonEncode({...a.manifest, 'entrypoint': null}),
      jsonEncode({...a.manifest, 'entrypoint': 123}),
    ]) {
      await manifest.writeAsString(raw);
      expect(await otherStore.current('utilities'), isNull, reason: raw);
    }
    await manifest.delete();
    expect(await store.current('utilities'), isNull);
    await manifest.writeAsString(original);
    expect((await otherStore.current('utilities'))!.bundleId, installed.bundleId);
    final complete = File('${installed.dir.path}/.complete');
    await complete.delete();
    expect(await store.current('utilities'), isNull);
  });

  test('cross-instance installs queue staging, pointer switch and prune, without blocking other apps', () async {
    final initial = await install(store, a);
    final before = await pointer().readAsString();
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final secondEntered = Completer<void>();
    final releaseSecond = Completer<void>();
    addTearDown(() {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      if (!releaseSecond.isCompleted) releaseSecond.complete();
    });

    final first = install(
      store,
      b,
      revision: 2,
      beforeSwitch: () async {
        firstEntered.complete();
        await releaseFirst.future;
      },
    );
    await firstEntered.future;
    final second = install(
      otherStore,
      c,
      revision: 3,
      beforeSwitch: () async {
        expect((await store.current('utilities'))!.bundleId, b.bundleId);
        expect(await version(b).exists(), isTrue);
        secondEntered.complete();
        await releaseSecond.future;
      },
    );

    // An independent install is an event barrier: the queued operation must not have written
    // even its candidate version yet, while an unrelated app can finish completely.
    final unrelated = await install(otherStore, d, appId: 'other');
    expect(unrelated.bundleId, d.bundleId);
    expect(secondEntered.isCompleted, isFalse);
    expect(await version(c).exists(), isFalse);
    expect(await pointer().readAsString(), before);
    expect(utf8.decode((await store.read(initial, 'index.html'))!), 'A');

    releaseFirst.complete();
    final installedB = await first;
    expect(installedB.bundleId, b.bundleId);
    expect(installedB.revision, 2);
    expect(installedB.title, 'version 2');
    expect(installedB.contractHash, 'contract 2');
    await secondEntered.future;
    expect((await otherStore.current('utilities'))!.bundleId, b.bundleId);
    releaseSecond.complete();
    final installedC = await second;
    expect(installedC.bundleId, c.bundleId);
    expect(installedC.revision, 3);
    expect(installedC.epoch, 'epoch 3');
    final json = jsonDecode(await pointer().readAsString()) as Map<String, dynamic>;
    expect(json['bundleId'], c.bundleId);
    expect(json['previous'], b.bundleId);
    expect(await version(a).exists(), isFalse);
    expect(await version(b).exists(), isTrue);
    expect(utf8.decode((await otherStore.read(installedC, 'index.html'))!), 'C');
    expectNoTemporaryFiles();
  });

  test('an aborted queued install cleans only its candidate and releases the next operation', () async {
    await install(store, a);
    final before = await pointer().readAsString();
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final failed = install(
      store,
      b,
      revision: 2,
      beforeSwitch: () async {
        entered.complete();
        await release.future;
        throw StateError('abort B');
      },
    );
    final failure = expectLater(failed, throwsStateError);
    await entered.future;
    final next = install(
      otherStore,
      c,
      revision: 3,
      beforeSwitch: () async {
        expect(await pointer().readAsString(), before);
        expect(await version(b).exists(), isFalse);
      },
    );
    await install(store, d, appId: 'other');
    expect(await version(c).exists(), isFalse);
    release.complete();
    await failure;
    expect((await next).bundleId, c.bundleId);
    expect((await store.current('utilities'))!.revision, 3);
    expectNoTemporaryFiles();
    // A fresh operation also works after the queue drains.
    expect((await install(otherStore, d, revision: 4)).bundleId, d.bundleId);
  });

  for (final abort in [false, true]) {
    test(
      'overlapping metadata-only installs ${abort ? 'recover after failure' : 'keep each pointer identity intact'}',
      () async {
        const identityA = PreviewIdentity(buildId: 'build_A', baseRevision: 0);
        const identityB = PreviewIdentity(buildId: 'build_B', baseRevision: 1);
        const identityC = PreviewIdentity(buildId: 'build_C', baseRevision: 2);
        await install(store, a, preview: identityA);
        final before = await pointer().readAsString();
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final first = install(
          store,
          a,
          preview: identityB,
          beforeSwitch: () async {
            entered.complete();
            await release.future;
            if (abort) throw StateError('abort metadata');
          },
        );
        final failure = abort ? expectLater(first, throwsStateError) : null;
        await entered.future;
        var secondStarted = false;
        final second = install(
          otherStore,
          a,
          preview: identityC,
          beforeSwitch: () async {
            secondStarted = true;
            final current = (await store.current('utilities'))!;
            expect(current.preview, abort ? identityA : identityB);
            if (abort) expect(await pointer().readAsString(), before);
            expect(current.bundleId, a.bundleId);
            expect(await store.read(current, 'index.html'), isNotNull);
          },
        );
        await install(otherStore, d, appId: 'other');
        expect(secondStarted, isFalse);
        expect(await pointer().readAsString(), before);
        release.complete();
        if (failure != null) {
          await failure;
        } else {
          expect((await first).preview, identityB);
        }
        final updated = await second;
        expect(updated.preview, identityC);
        expect(updated.revision, 1);
        expect(updated.bundleId, a.bundleId);
        expect((await store.current('utilities'))!.preview, identityC);
        expect(await Directory('${store.root.path}/apps/utilities/versions').list().length, 1);
        expectNoTemporaryFiles();
      },
    );
  }

  test('same app in another cache root is independent', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final first = install(
      store,
      a,
      beforeSwitch: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;
    final independent = BundleStore(Directory('${tmp.path}/independent'));
    expect((await install(independent, b)).bundleId, b.bundleId);
    expect(await store.current('utilities'), isNull);
    release.complete();
    await first;
  });

  test('pins across stores retain displayed A through B/C, until all handles release and a later prune', () async {
    final installedA = await install(store, a);
    final firstPin = store.pin(installedA);
    final secondPin = otherStore.pin(installedA);
    addTearDown(() {
      firstPin.release();
      secondPin.release();
    });
    firstPin.release();
    firstPin.release(); // cannot consume the other handle's reference
    final updateB = install(otherStore, b, revision: 2);
    final updateC = install(store, c, revision: 3);
    await Future.wait([updateB, updateC]); // two already-started updates must not prune displayed A
    expect(await version(a).exists(), isTrue);
    expect(utf8.decode((await otherStore.read(installedA, 'index.html'))!), 'A');
    secondPin.release();
    secondPin.release();
    expect(await version(a).exists(), isTrue, reason: 'release is synchronous retention bookkeeping, not I/O');
    await install(otherStore, d, revision: 4);
    expect(await version(a).exists(), isFalse);
    expect(await version(b).exists(), isFalse);
    expect(await version(c).exists(), isTrue);
    expectNoTemporaryFiles();
  });

  test('all pinned versions survive, and replacement is acquired before the old pin releases', () async {
    final installedA = await install(store, a);
    final pinA = store.pin(installedA);
    final installedB = await install(otherStore, b, revision: 2);
    final pinB = otherStore.pin(installedB);
    addTearDown(() {
      pinA.release();
      pinB.release();
    });
    await install(store, c, revision: 3);
    await install(otherStore, d, revision: 4);
    expect(await version(a).exists(), isTrue);
    expect(await version(b).exists(), isTrue);
    pinA.release();
    await install(store, c, revision: 5);
    expect(await version(a).exists(), isFalse);
    expect(await version(b).exists(), isTrue);
    expect(await store.read(installedB, 'index.html'), isNotNull);
    pinB.release();
    await install(otherStore, d, revision: 6);
    expect(await version(b).exists(), isFalse);
  });

  test('pins do not retain the same digest in other apps or cache roots', () async {
    final installedA = await install(store, a);
    final pin = store.pin(installedA);
    addTearDown(pin.release);
    final independent = BundleStore(Directory('${tmp.path}/independent'));
    for (final target in [store, independent]) {
      final appId = identical(target, store) ? 'other' : 'utilities';
      await install(target, a, appId: appId);
      await install(target, b, appId: appId);
      await install(target, c, appId: appId);
      expect(await version(a, appId: appId, inStore: target).exists(), isFalse);
    }
    expect(await version(a).exists(), isTrue);
  });

  test('explicit remove waits for an active install on another store', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final pending = install(
      store,
      a,
      beforeSwitch: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;
    final removal = otherStore.remove('utilities');
    await install(store, b, appId: 'other');
    expect(await version(a).exists(), isTrue);
    release.complete();
    expect((await pending).bundleId, a.bundleId);
    await removal;
    expect(await store.current('utilities'), isNull);
    expect(await version(a).exists(), isFalse);
  });
}
