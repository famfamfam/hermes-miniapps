import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:http/http.dart' as http;

import 'native_association_support.dart';
import 'support.dart';

void main() {
  // The controller's frame-safe notifications read the scheduler phase.
  TestWidgetsFlutterBinding.ensureInitialized();

  NativeHarness harness({NativeOwnerSnapshot? owner}) {
    final result = NativeHarness(snapshot: owner);
    addTearDown(result.dispose);
    return result;
  }

  final changedOwners = <String, NativeOwnerSnapshot>{
    'connection': nativeOwner(id: 'other_connection'),
    'profile': nativeOwner(profile: 'other_profile'),
    'null profile': nativeOwner(profile: null),
    'empty profile': nativeOwner(profile: ''),
    'endpoint': nativeOwner(endpoint: 'https://other.synthetic.invalid'),
    'routes': nativeOwner(routes: '/other-route'),
    'API credential': nativeOwner(apiKey: 'different_synthetic_key'),
    'dashboard credential': nativeOwner(dashboard: 'different_synthetic_password'),
  };

  test('fingerprint and storage keys are opaque, bounded and preserve field/null boundaries', () {
    expect(nativeContextFingerprint([null]), isNot(nativeContextFingerprint([''])));
    expect(nativeContextFingerprint(['ab', 'c']), isNot(nativeContextFingerprint(['a', 'bc'])));
    final key = nativeAssociationStorageKey('owner/with-secret-looking-text');
    expect(key, matches(RegExp(r'^hermes_surfaces_association_v1_[a-f0-9]{64}$')));
    expect(key, isNot(contains('owner')));
    expect(nativeOwner().sameContext(nativeOwner(label: 'Renamed')), isTrue);
    expect(nativeOwner(profile: null).sameContext(nativeOwner(profile: '')), isFalse);
    for (final changed in changedOwners.values) {
      expect(nativeOwner().sameContext(changed), isFalse);
    }
  });

  test('target leases never revive and cheap epoch guard detects same-frame A-B-A', () {
    final target = NativeActiveTarget();
    addTearDown(target.dispose);
    final a = target.select(nativeOwner());
    final epoch = target.epoch;
    expect(target.selectIfChanged(nativeOwner(label: 'Same snapshot')), same(a));
    expect(target.epoch, epoch);
    target.select(nativeOwner(id: 'B'));
    final newA = target.selectIfChanged(nativeOwner());
    expect(a.isCurrent, isFalse);
    expect(newA.isCurrent, isTrue);
    expect(target.epoch, greaterThan(epoch));
    target.clear();
    expect(newA.isCurrent, isFalse);
    expect(target.current, isNull);
  });

  test('typed mutation operations overlap, settle in reverse order, and finish once', () {
    final tracker = NativeMutationTracker();
    addTearDown(tracker.dispose);
    var notifications = 0;
    tracker.addListener(() => notifications++);
    // Simulated read-only/no-op manager initialize has no begin and no notification.
    expect(tracker.pendingOperations, isEmpty);
    expect(notifications, 0);
    final firstManager = tracker.begin();
    final secondManager = tracker.begin();
    expect(notifications, 2);
    expect(tracker.pendingCount, 2);
    expect(() => tracker.pendingOperations.clear(), throwsUnsupportedError);
    secondManager.finish(success: false);
    expect(tracker.isPending, isTrue);
    expect(secondManager.outcome, NativeMutationOutcome.failure);
    expect(tracker.lastOutcome, NativeMutationOutcome.failure);
    firstManager.finish(success: true);
    expect(tracker.pendingCount, 0);
    expect(tracker.lastSettled, same(firstManager));
    expect(tracker.lastOutcome, NativeMutationOutcome.success);
    final epoch = tracker.epoch;
    firstManager.finish(success: false);
    expect(tracker.epoch, epoch);
    expect(notifications, 4);
    expect(firstManager.outcome, NativeMutationOutcome.success);
  });

  test('mutation run keeps failed transaction pending through simulated rollback', () async {
    final tracker = NativeMutationTracker();
    addTearDown(tracker.dispose);
    final rollback = Completer<void>();
    final result = tracker.run<void>(() async {
      try {
        throw StateError('synthetic write failed');
      } catch (_) {
        await rollback.future;
        rethrow;
      }
    });
    final rejected = expectLater(result, throwsStateError);
    expect(tracker.isPending, isTrue);
    rollback.complete();
    await rejected;
    expect(tracker.isPending, isFalse);
    expect(tracker.lastOutcome, NativeMutationOutcome.failure);
    expect(await tracker.run(() async => 7), 7);
    expect(tracker.lastOutcome, NativeMutationOutcome.success);
  });

  test('startup reads only native namespace with separate bearer, persisted generation and flags', () async {
    final h = harness();
    h.seed(settings: nativeSettings(strict: false, seal: false));
    final c = h.make();
    await flushNative();
    final binding = c.activeConnection.value!;
    expect(h.reads, [nativeAssociationStorageKey(h.owner.connectionId)]);
    expect(h.committedReads, 2);
    expect(h.writes, isEmpty);
    expect(h.supportReads, 0);
    expect(h.keyReads, 0);
    expect(h.clients, isEmpty);
    expect(binding.config.connectionId, h.owner.connectionId);
    expect(binding.config.profileId, h.owner.profileId);
    expect(binding.config.token, 'synthetic_surfaces_bearer');
    expect(binding.config.token, isNot('synthetic_gateway_key'));
    expect(binding.config.deviceId, 'explicit_synthetic_device');
    expect(binding.config.credentialGeneration, 'synthetic_persisted_generation');
    expect(binding.strictNetworkBlock, isFalse);
    expect(binding.sealNetwork, isFalse);
    expect(binding.scope, isNot(contains('synthetic')));
  });

  for (final profile in <String?>[null, '']) {
    test('nullable profile $profile is exactly retained in configuration and cache scope', () async {
      final h = harness(owner: nativeOwner(profile: profile));
      h.seed();
      final c = h.make();
      await flushNative();
      expect(c.activeConnection.value!.config.profileId, profile);
      final token = c.beginConfiguration();
      expect(await c.readConfiguration(token), isNotNull);
      expect(c.isConfigurationCurrent(token), isTrue);
      c.endConfiguration(token);
      await flushNative();
      expect(c.activeConnection.value, isNotNull);
    });
  }

  final corruptions = <String, void Function(Map<String, dynamic>)>{
    'wrong version': (j) => j['version'] = 2,
    'non-integer version': (j) => j['version'] = 1.0,
    'wrong connection': (j) => j['connectionId'] = 'other',
    'wrong profile': (j) => j['profileId'] = null,
    'missing profile': (j) => j.remove('profileId'),
    'wrong fingerprint': (j) => j['contextFingerprint'] = 'other',
    'missing generation': (j) => j.remove('generation'),
    'empty generation': (j) => j['generation'] = '',
    'invalid URL': (j) => j['baseUri'] = 'https://user:synthetic@synthetic.invalid',
    'URL query': (j) => j['baseUri'] = 'https://synthetic.invalid?bearer=synthetic',
    'empty bearer': (j) => j['bearer'] = '',
    'empty device': (j) => j['deviceId'] = '',
    'wrong network flags': (j) => j['sealNetwork'] = 'true',
    'control-character bearer': (j) => j['bearer'] = 'synthetic\r\nheader',
  };
  for (final corruption in corruptions.entries) {
    test('${corruption.key} record fails closed with no resource or settings writes', () async {
      final h = harness();
      final json = associationJson(h.owner);
      corruption.value(json);
      h.storage[nativeAssociationStorageKey(h.owner.connectionId)] = jsonEncode(json);
      final c = h.make();
      await flushNative();
      expect(c.activeConnection.value, isNull);
      expect(c.status.value, isNotNull);
      expect(c.status.value, isNot(contains('synthetic')));
      expect(h.writes, isEmpty);
      expect(h.keyReads, 0);
      expect(h.supportReads, 0);
      expect(h.clients, isEmpty);
      await c.openChat();
      expect(h.chatCalls, 1);
    });
  }

  for (final raw in <String?>[null, '{broken synthetic-secret', '[]']) {
    test('missing or malformed record $raw leaves chat available without fallback', () async {
      final h = harness();
      if (raw != null) h.storage[nativeAssociationStorageKey(h.owner.connectionId)] = raw;
      final c = h.make();
      await flushNative();
      expect(c.activeConnection.value, isNull);
      expect(c.status.value, isNot(contains('synthetic-secret')));
      await c.openChat();
      expect(h.chatCalls, 1);
      expect(h.writes, isEmpty);
    });
  }

  test('secure read/committed loader errors are sanitized and never use old memory binding', () async {
    final h = harness();
    h.seed();
    final c = h.make();
    await flushNative();
    h.read = (_) async => throw StateError('raw-synthetic-secret https://bad.invalid?cookie=secret');
    final load = c.reload();
    expect(c.activeConnection.value, isNull);
    await load;
    expect(c.status.value, isNot(contains('raw-synthetic-secret')));
    expect(c.activeConnection.value, isNull);
    h.read = null;
    h.committed = () async => throw StateError('raw-synthetic-secret');
    await c.reload();
    expect(c.activeConnection.value, isNull);
    expect(c.status.value, isNot(contains('raw-synthetic-secret')));
  });

  for (final change in changedOwners.entries) {
    for (final stage in ['committed before', 'association', 'committed after']) {
      test('${change.key} selection during $stage load cannot publish stale owner', () async {
        final h = harness();
        h.seed();
        final gate = Completer<void>();
        var committedCalls = 0;
        h.committed = () async {
          committedCalls++;
          if (stage == 'committed before' && committedCalls == 1 || stage == 'committed after' && committedCalls == 2) {
            await gate.future;
          }
          return h.owner;
        };
        h.read = (key) async {
          if (stage == 'association') await gate.future;
          return h.storage[key];
        };
        final c = h.make();
        await flushNative();
        h.target.select(change.value);
        expect(c.activeConnection.value, isNull);
        gate.complete();
        await flushNative();
        expect(c.activeConnection.value, isNull);
        await c.openChat();
        expect(h.chatCalls, 0);
      });
    }
  }

  test('same-frame A-B-A, disposal and old configuration callbacks never reclaim target', () async {
    final h = harness();
    h.seed();
    final gate = Completer<String?>();
    h.read = (_) => gate.future;
    final c = h.make();
    await flushNative();
    final token = c.beginConfiguration();
    final configRead = c.readConfiguration(token);
    h.target.select(nativeOwner(id: 'B'));
    final newLease = h.target.select(h.owner);
    expect(c.lease.isCurrent, isFalse);
    gate.complete(h.storage.values.single);
    await configRead;
    await flushNative();
    expect(c.activeConnection.value, isNull);
    expect(c.isConfigurationCurrent(token), isFalse);
    expect(await c.saveConfiguration(token, nativeSettings()), NativeAssociationSaveResult.stale);
    c.endConfiguration(token);
    await c.openChat();
    expect(h.chatCalls, 0);
    c.dispose();
    h.read = null;
    final fresh = h.make(lease: newLease);
    await flushNative();
    expect(fresh.activeConnection.value, isNotNull);
    await fresh.openChat();
    expect(h.chatCalls, 1);
  });

  test('overlapping native mutations invalidate synchronously and reconcile only pending zero', () async {
    final h = harness();
    h.seed();
    final c = h.make();
    await flushNative();
    final before = h.committedReads;
    final managerA = h.mutations.begin();
    expect(c.activeConnection.value, isNull);
    final managerB = h.mutations.begin();
    managerB.finish(success: false);
    await flushNative();
    expect(h.committedReads, before);
    expect(c.activeConnection.value, isNull);
    managerA.finish(success: true);
    await flushNative();
    expect(h.committedReads, before + 2);
    expect(c.activeConnection.value, isNotNull);
    final reads = h.committedReads;
    await flushNative(); // no-op initialize/read never signals a reload -> initialize loop.
    expect(h.committedReads, reads);
  });

  for (final change in changedOwners.entries) {
    test('${change.key} committed state never substitutes actual immutable chat snapshot', () async {
      final h = harness();
      h.seed();
      final c = h.make();
      await flushNative();
      final transaction = h.mutations.begin();
      expect(c.activeConnection.value, isNull);
      h.committedOwner = change.value;
      h.seed(forOwner: change.value);
      transaction.finish(success: true);
      await flushNative();
      expect(c.activeConnection.value, isNull);
      expect(c.owner, same(h.owner));
      expect(c.notice.value, NativeAssociationNotice.contextMismatch);
      await c.openChat(); // Existing chat snapshot stays usable; Apps doesn't rewrite it.
      expect(h.chatCalls, 1);
      final freshLease = h.target.select(change.value);
      final fresh = h.make(snapshot: change.value, lease: freshLease);
      await flushNative();
      expect(fresh.activeConnection.value, isNotNull);
    });
  }

  test('failed native settlement freshly reads actual rollback result, not proposed memory', () async {
    final h = harness();
    h.seed();
    final c = h.make();
    await flushNative();
    final op = h.mutations.begin();
    h.committedOwner = nativeOwner(apiKey: 'partially_written_synthetic_key');
    op.finish(success: false); // Simulated rollback failure leaves actual state different.
    await flushNative();
    expect(c.activeConnection.value, isNull);
    expect(h.mutations.lastOutcome, NativeMutationOutcome.failure);
    h.committedOwner = h.owner;
    await c.reload();
    expect(c.activeConnection.value, isNotNull);
  });

  test('explicit save persists separate record/readback and activates only a fresh durable read', () async {
    final h = harness();
    final c = h.make();
    await flushNative();
    final token = c.beginConfiguration();
    expect(await c.readConfiguration(token), isNull);
    final result = c.saveConfiguration(token, nativeSettings(bearer: 'explicit_separate_bearer'));
    expect(c.activeConnection.value, isNull);
    expect(await result, NativeAssociationSaveResult.saved);
    await flushNative();
    // The open configuration keeps Apps unbound, even after the durable write settled.
    expect(c.activeConnection.value, isNull);
    c.endConfiguration(token);
    await flushNative();
    final saved = jsonDecode(h.writes.single.$2) as Map<String, dynamic>;
    expect(saved['version'], 1);
    expect(saved['profileId'], h.owner.profileId);
    expect(saved['contextFingerprint'], h.owner.contextFingerprint);
    expect(saved['generation'], isNotEmpty);
    expect(saved['generation'], isNot('synthetic_persisted_generation'));
    expect(saved['bearer'], 'explicit_separate_bearer');
    expect(h.writes.single.$2, isNot(contains('synthetic_gateway_key')));
    expect(h.writes.single.$2, isNot(contains('synthetic_dashboard_password')));
    expect(h.reads.length, greaterThanOrEqualTo(4)); // startup/config/readback/fresh load.
    expect(c.activeConnection.value!.config.credentialGeneration, saved['generation']);
    expect(h.keyReads, 0);
    expect(h.supportReads, 0);
  });

  for (final invalid in <NativeAssociationSettings>[
    nativeSettings(url: 'relative/path'),
    nativeSettings(url: 'ftp://synthetic.invalid'),
    nativeSettings(url: 'https://user:secret@synthetic.invalid'),
    nativeSettings(url: 'https://synthetic.invalid?token=secret'),
    nativeSettings(url: 'https://synthetic.invalid#secret'),
    nativeSettings(bearer: ''),
    nativeSettings(device: ''),
    // The server pairs/authorizes only [A-Za-z0-9_-]{1,64}: these would save, then fail every request.
    nativeSettings(device: 'Pixel 7'),
    nativeSettings(device: 'phone.local'),
    nativeSettings(device: 'телефон'),
    nativeSettings(device: 'a' * 65),
  ]) {
    test('invalid explicit settings fail before secure write and keep correction token', () async {
      final h = harness();
      h.seed();
      final c = h.make();
      await flushNative();
      final token = c.beginConfiguration();
      expect(await c.saveConfiguration(token, invalid), NativeAssociationSaveResult.invalid);
      expect(h.writes, isEmpty);
      expect(c.activeConnection.value, isNull);
      expect(c.isConfigurationCurrent(token), isTrue);
      c.endConfiguration(token);
      await flushNative();
      expect(c.activeConnection.value, isNotNull);
    });
  }

  test('device id accepts exactly the server vocabulary, including the 64-character boundary', () async {
    for (final ok in ['a', 'Pixel_7-main', 'A' * 64, '0-9_z']) {
      expect(NativeAssociationSettings.isValidDeviceId(ok), isTrue, reason: ok);
    }
    for (final bad in ['', ' ', 'a b', 'a.b', 'a/b', 'a' * 65, 'ключ', 'a\n']) {
      expect(NativeAssociationSettings.isValidDeviceId(bad), isFalse, reason: bad);
    }
    final h = harness();
    h.seed();
    final c = h.make();
    await flushNative();
    final token = c.beginConfiguration();
    expect(await c.saveConfiguration(token, nativeSettings(device: 'A' * 64)), NativeAssociationSaveResult.saved);
  });

  for (final stage in ['committed before', 'write', 'readback', 'committed after']) {
    for (final action in ['target A-B-A', 'mutation', 'dispose']) {
      test('$action during save $stage cannot publish or start unauthorized queued work', () async {
        final h = harness();
        h.seed();
        final c = h.make();
        await flushNative();
        final token = c.beginConfiguration();
        final gate = Completer<void>();
        var committedCalls = 0;
        h.committed = () async {
          committedCalls++;
          if (stage == 'committed before' && committedCalls == 1 || stage == 'committed after' && committedCalls == 2) {
            await gate.future;
          }
          return h.committedOwner;
        };
        h.write = (key, value) async {
          if (stage == 'write') await gate.future;
          h.storage[key] = value;
        };
        h.read = (key) async {
          if (stage == 'readback') await gate.future;
          return h.storage[key];
        };
        final result = c.saveConfiguration(token, nativeSettings());
        expect(c.activeConnection.value, isNull);
        await flushNative();
        NativeMutationOperation? op;
        if (action == 'target A-B-A') {
          h.target.select(nativeOwner(id: 'B'));
          h.target.select(h.owner);
        } else if (action == 'mutation') {
          op = h.mutations.begin();
          h.committedOwner = nativeOwner(apiKey: 'changed_during_save');
        } else {
          c.dispose();
        }
        gate.complete();
        expect(await result, NativeAssociationSaveResult.stale);
        op?.finish(success: false);
        await flushNative();
        expect(c.activeConnection.value, isNull);
        if (stage == 'committed before') expect(h.writes, isEmpty);
      });
    }
  }

  for (final error in ['write', 'readback exception', 'readback mismatch', 'committed after']) {
    test('$error failed save stays unbound until explicit reload, then reflects only durable state', () async {
      final h = harness();
      h.seed();
      final c = h.make();
      await flushNative();
      final token = c.beginConfiguration();
      if (error == 'write') {
        h.write = (_, _) async => throw StateError('raw-synthetic-secret');
      } else if (error == 'readback exception') {
        h.read = (_) async => throw StateError('raw-synthetic-secret');
      } else if (error == 'readback mismatch') {
        h.read = (_) async => jsonEncode(associationJson(h.owner));
      } else {
        var calls = 0;
        h.committed = () async {
          if (++calls == 2) throw StateError('raw-synthetic-secret');
          return h.owner;
        };
      }
      expect(
        await c.saveConfiguration(token, nativeSettings(bearer: 'new_separate_bearer')),
        NativeAssociationSaveResult.failed,
      );
      await flushNative();
      expect(c.activeConnection.value, isNull);
      expect(c.status.value, isNot(contains('raw-synthetic-secret')));
      c.endConfiguration(token);
      await flushNative();
      expect(c.activeConnection.value, isNull);
      h.read = null;
      h.write = null;
      h.committed = null;
      final durable = jsonDecode(h.storage.values.single) as Map;
      await c.reload(); // Explicit subsequent fresh exact-context read is allowed.
      // Whatever is bound is the verified durable record, never the in-memory proposal.
      expect(c.activeConnection.value!.config.token, durable['bearer']);
      expect(c.activeConnection.value!.config.credentialGeneration, durable['generation']);
      if (error == 'write') expect(durable['bearer'], 'synthetic_surfaces_bearer');
    });
  }

  test('a failed save latches only its own controller; a sibling freshly reads the durable record', () async {
    final h = harness();
    h.seed();
    final failing = h.make();
    final sibling = h.make();
    await flushNative();
    final token = failing.beginConfiguration();
    h.write = (_, _) async => throw StateError('raw-synthetic-secret');
    expect(await failing.saveConfiguration(token, nativeSettings(bearer: 'lost')), NativeAssociationSaveResult.failed);
    await flushNative();
    expect(failing.activeConnection.value, isNull);
    expect(sibling.activeConnection.value!.config.token, 'synthetic_surfaces_bearer');
    // A controller created while the save is still pending joins by a fresh read at drain.
    h.write = null;
    final gate = Completer<void>();
    h.write = (key, value) async {
      await gate.future;
      h.storage[key] = value;
    };
    final retryToken = failing.beginConfiguration();
    final retry = failing.saveConfiguration(retryToken, nativeSettings(bearer: 'retry_bearer'));
    await flushNative();
    final joined = h.make();
    await flushNative();
    expect(joined.activeConnection.value, isNull);
    gate.complete();
    expect(await retry, NativeAssociationSaveResult.saved);
    await flushNative();
    expect(joined.activeConnection.value!.config.token, 'retry_bearer');
    failing.endConfiguration(retryToken);
    await flushNative();
    expect(failing.activeConnection.value!.config.token, 'retry_bearer');
  });

  test('two live controllers serialize same-ID writes and never activate before all save outcomes', () async {
    final h = harness();
    h.seed();
    final a = h.make();
    final b = h.make();
    await flushNative();
    final ta = a.beginConfiguration();
    final tb = b.beginConfiguration();
    final firstWrite = Completer<void>();
    var concurrent = 0;
    var maximum = 0;
    h.write = (key, value) async {
      concurrent++;
      if (concurrent > maximum) maximum = concurrent;
      if (h.writes.length == 1) await firstWrite.future;
      h.storage[key] = value;
      concurrent--;
    };
    final one = a.saveConfiguration(ta, nativeSettings(bearer: 'first_bearer'));
    final two = b.saveConfiguration(tb, nativeSettings(bearer: 'second_bearer'));
    await flushNative();
    expect(h.writes.length, 1);
    expect(a.activeConnection.value, isNull);
    expect(b.activeConnection.value, isNull);
    firstWrite.complete();
    expect(await one, NativeAssociationSaveResult.saved);
    expect(await two, NativeAssociationSaveResult.saved);
    await flushNative();
    a.endConfiguration(ta);
    b.endConfiguration(tb);
    await flushNative();
    expect(maximum, 1);
    expect(h.writes.length, 2);
    final first = jsonDecode(h.writes[0].$2) as Map;
    final second = jsonDecode(h.writes[1].$2) as Map;
    expect(first['generation'], isNot(second['generation']));
    expect(a.activeConnection.value!.config.token, 'second_bearer');
    expect(b.activeConnection.value!.config.credentialGeneration, second['generation']);
  });

  test('queued stale target skips write; older in-flight generation never overwrites a newer save', () async {
    final h = harness();
    h.seed();
    final c = h.make();
    await flushNative();
    final token = c.beginConfiguration();
    final gate = Completer<void>();
    h.write = (key, value) async {
      if (h.writes.length == 1) await gate.future;
      h.storage[key] = value;
    };
    final older = c.saveConfiguration(token, nativeSettings(bearer: 'older_bearer'));
    await flushNative();
    final newer = c.saveConfiguration(token, nativeSettings(bearer: 'newer_bearer'));
    gate.complete();
    expect(await older, NativeAssociationSaveResult.stale);
    expect(await newer, NativeAssociationSaveResult.saved);
    await flushNative();
    expect(c.activeConnection.value, isNull); // Token still open; nothing binds yet.
    c.endConfiguration(token);
    await flushNative();
    expect(c.activeConnection.value!.config.token, 'newer_bearer');
    expect((jsonDecode(h.storage.values.single) as Map)['bearer'], 'newer_bearer');

    final freshToken = c.beginConfiguration();
    final writeGate = Completer<void>();
    h.write = (key, value) async {
      await writeGate.future;
      h.storage[key] = value;
    };
    final first = c.saveConfiguration(freshToken, nativeSettings(bearer: 'inflight_bearer'));
    await flushNative();
    final second = c.saveConfiguration(freshToken, nativeSettings(bearer: 'must_not_write'));
    h.target.select(nativeOwner(id: 'B'));
    writeGate.complete();
    expect(await first, NativeAssociationSaveResult.stale);
    expect(await second, NativeAssociationSaveResult.stale);
    expect(h.writes.where((w) => w.$2.contains('must_not_write')), isEmpty);
  });

  for (final callback in ['root', 'key']) {
    for (final action in ['target A-B-A', 'mutation', 'committed mismatch', 'dispose']) {
      test('$action during $callback callback rejects late resource', () async {
        final h = harness();
        h.seed();
        final c = h.make();
        await flushNative();
        final gate = Completer<void>();
        h.support = () async {
          await gate.future;
          return Directory('unused_synthetic_support');
        };
        h.key = () async {
          await gate.future;
          return null;
        };
        final pending = callback == 'root' ? c.applicationSupportDirectory() : c.loadApproverKey();
        final rejected = expectLater(pending, throwsStateError);
        NativeMutationOperation? op;
        if (action == 'target A-B-A') {
          h.target.select(nativeOwner(id: 'B'));
          h.target.select(h.owner);
        } else if (action == 'mutation') {
          op = h.mutations.begin();
          h.committedOwner = nativeOwner(routes: '/changed');
        } else if (action == 'committed mismatch') {
          h.committedOwner = nativeOwner(endpoint: 'https://changed.synthetic.invalid');
        } else {
          c.dispose();
        }
        gate.complete();
        await rejected;
        expect(c.activeConnection.value, isNull);
        op?.finish(success: false);
        await flushNative();
      });
    }
  }

  test('missing or corrupt existing identity never generates/replaces it and preserves reads', () async {
    final h = harness();
    h.seed();
    final c = h.make();
    await flushNative();
    expect(await c.loadApproverKey(), isNull);
    expect(c.activeConnection.value, isNotNull);
    h.key = () async => throw StateError('raw-synthetic-key-material');
    await expectLater(
      c.loadApproverKey(),
      throwsA(predicate((e) => e is StateError && !e.toString().contains('raw-synthetic-key-material'))),
    );
    expect(c.activeConnection.value, isNotNull);
    expect(h.keyReads, 2);
    expect(h.writes, isEmpty);
  });

  test('fresh published/preview clients are isolated, reused or wrong-binding clients are rejected', () async {
    final h = harness();
    h.seed();
    final c = h.make();
    await flushNative();
    final published = c.activeConnection.value!;
    final preview = SurfacesConnection(config: published.config.forPreview());
    final one = c.createSurfacesClient(published);
    final two = c.createSurfacesClient(preview);
    expect(one, isNot(same(two)));
    expect(h.clients.length, 2);
    expect(h.clients[1].connection.scope, isNot(published.scope));
    h.client = (_) => one;
    expect(() => c.createSurfacesClient(published), throwsStateError);
    expect(h.clients[0].closes, 0); // Do not close a previously issued/shared client again.
    expect(() => c.createSurfacesClient(connection(token: 'wrong_bearer')), throwsStateError);
    h.client = (binding) {
      final fresh = FakeClient(binding, h.server.respond);
      h.clients.add(fresh);
      h.target.clear();
      return fresh;
    };
    expect(() => c.createSurfacesClient(published), throwsStateError);
    expect(h.clients.last.closes, 1);
    expect(c.activeConnection.value, isNull);
  });

  test('the host\'s file pickers and chat starter are what the controller hands to pages, and nothing by default', () async {
    final h = harness();
    h.seed();
    final bare = h.make();
    expect(bare.fileActions, isNull);
    expect(bare.sendToHermes, isNull);
    final actions = _NoActions();
    Future<bool> starter(String text) async => true;
    final equipped = h.make(fileActions: actions, sendToHermes: starter);
    expect(identical(equipped.fileActions, actions), isTrue);
    expect(identical(equipped.sendToHermes, starter), isTrue);
  });

  test('client, root and chat callback errors never interpolate native secrets', () async {
    final h = harness();
    h.seed();
    final c = h.make();
    await flushNative();
    h.client = (_) => throw http.ClientException('raw-synthetic-secret');
    expect(
      () => c.createSurfacesClient(c.activeConnection.value!),
      throwsA(predicate((e) => e is StateError && !e.toString().contains('raw-synthetic-secret'))),
    );
    h.support = () async => throw StateError('raw-synthetic-secret');
    await expectLater(
      c.applicationSupportDirectory(),
      throwsA(predicate((e) => e is StateError && !e.toString().contains('raw-synthetic-secret'))),
    );
    h.chat = () async => throw StateError('raw-synthetic-secret');
    await expectLater(
      c.openChat(),
      throwsA(predicate((e) => e is StateError && !e.toString().contains('raw-synthetic-secret'))),
    );
  });
}

class _NoActions extends HostFileActions {
  @override
  Future<PickedFile?> pick(BuildContext context, {required List<String> accept}) async => null;

  @override
  Future<FileOfferResult> offer(BuildContext context, {required String name, required String mime, required Uint8List bytes}) async =>
      FileOfferResult.cancelled;
}
