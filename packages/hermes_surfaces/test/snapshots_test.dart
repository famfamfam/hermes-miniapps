import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/src/snapshots.dart';

Snapshot snap(int rev) =>
    Snapshot(fetchedAt: DateTime.utc(2026, 10, 14, 12, rev % 60), dataRev: rev, results: {'q': 'rev $rev'});

void main() {
  late Directory tmp;
  late SnapshotCache cache;
  late Directory dir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ms_snapshots_test');
    cache = SnapshotCache(tmp);
    dir = Directory('${tmp.path}/apps/zhkh/snapshots');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  List<String> names() => dir.listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last).toList()..sort();

  group('concurrent writers (review finding 3)', () {
    test('identical groups finishing together all succeed and leave one file', () async {
      // A data-changed event or reload during the first query yields several puts for one key.
      for (var round = 0; round < 5; round++) {
        final results = await Future.wait([
          for (var i = 0; i < 8; i++)
            cache.put('zhkh', 'key', snap(round * 10 + i)).then<Object?>((_) => null, onError: (Object e) => e),
        ]);
        expect(results.whereType<Object>(), isEmpty, reason: 'round $round: a concurrent put must not throw');
        expect(names(), ['key.json'], reason: 'round $round: no temp file may be left behind');
        final stored = await cache.get('zhkh', 'key');
        expect(stored, isNotNull);
        expect(stored!.dataRev, inInclusiveRange(round * 10, round * 10 + 7));
      }
    });

    test('the last put issued wins', () async {
      await Future.wait([for (var i = 0; i < 6; i++) cache.put('zhkh', 'key', snap(i))]);
      expect((await cache.get('zhkh', 'key'))!.dataRev, 5);
    });

    test('writers of different keys and apps are independent', () async {
      await Future.wait([
        for (var i = 0; i < 6; i++) cache.put('zhkh', 'key$i', snap(i)),
        cache.put('other', 'key0', snap(100)),
      ]);
      for (var i = 0; i < 6; i++) {
        expect((await cache.get('zhkh', 'key$i'))!.dataRev, i);
      }
      expect((await cache.get('other', 'key0'))!.dataRev, 100);
      expect(names().where((n) => !n.endsWith('.json')), isEmpty);
    });

    test('a second cache object on the same root does not collide with the first', () async {
      final other = SnapshotCache(Directory('${tmp.path}/.'));
      final results = await Future.wait([
        for (var i = 0; i < 6; i++)
          (i.isEven ? cache : other).put('zhkh', 'key', snap(i)).then<Object?>((_) => null, onError: (Object e) => e),
      ]);
      expect(results.whereType<Object>(), isEmpty);
      expect(names(), ['key.json']);
    });
  });

  group('temporary files', () {
    test('a put that fails to publish leaves no temp file and keeps the old snapshot out of harm', () async {
      // A directory in the way makes the final rename fail on every platform.
      Directory('${dir.path}/key.json').createSync(recursive: true);
      await expectLater(cache.put('zhkh', 'key', snap(1)), throwsA(isA<FileSystemException>()));
      expect(names(), ['key.json'], reason: 'only the obstacle remains');
    });

    test('a failed put does not poison later puts for the same key', () async {
      final blocker = Directory('${dir.path}/key.json')..createSync(recursive: true);
      await expectLater(cache.put('zhkh', 'key', snap(1)), throwsA(isA<FileSystemException>()));
      blocker.deleteSync();
      await cache.put('zhkh', 'key', snap(2));
      expect((await cache.get('zhkh', 'key'))!.dataRev, 2);
      expect(names(), ['key.json']);
    });

    test('eviction removes abandoned temp files but never a fresh one from a writer in flight', () async {
      await cache.put('zhkh', 'seed', snap(0));
      final stale = File('${dir.path}/dead.1-2-3.tmp')..writeAsStringSync('{');
      stale.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
      final fresh = File('${dir.path}/live.4-5-6.tmp')..writeAsStringSync('{');
      await cache.put('zhkh', 'next', snap(1));
      expect(stale.existsSync(), isFalse, reason: 'an abandoned temp file must not stay forever');
      expect(fresh.existsSync(), isTrue, reason: 'a recent temp file may belong to a writer still running');
    });
  });

  group('eviction', () {
    test('keeps the newest maxFiles snapshots', () async {
      final small = SnapshotCache(tmp, maxFiles: 3);
      for (var i = 0; i < 5; i++) {
        await small.put('zhkh', 'k$i', snap(i));
        // File times can tie on coarse filesystems; spread them so "oldest" is well defined.
        File('${dir.path}/k$i.json').setLastModifiedSync(DateTime.now().subtract(Duration(minutes: 10 - i)));
      }
      await small.put('zhkh', 'k5', snap(5));
      expect(names(), ['k3.json', 'k4.json', 'k5.json']);
    });

    test('a file that vanishes while being evicted does not fail the put', () async {
      final small = SnapshotCache(tmp, maxFiles: 1);
      await small.put('zhkh', 'a', snap(1));
      await Future.wait([for (var i = 0; i < 6; i++) small.put('zhkh', 'b$i', snap(i))]);
      expect(names().where((n) => n.endsWith('.json')).length, 1);
    });
  });
}
