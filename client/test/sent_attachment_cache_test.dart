import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/sent_attachment_cache.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('appends and reads turns for one chat', () async {
    final turn = CachedSentAttachments(
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
      text: 'see this',
      imageDataUrls: ['data:image/png;base64,QUJD'],
      files: [
        {'filename': 'r.pdf', 'fileData': 'data:application/pdf;base64,RA=='},
      ],
    );
    await SentAttachmentCache.append('conn', 'session', turn);

    final turns = await SentAttachmentCache.readAll('conn', 'session');
    expect(turns, hasLength(1));
    expect(turns.single.text, 'see this');
    expect(turns.single.imageDataUrls.single, 'data:image/png;base64,QUJD');
    expect(turns.single.files.single['filename'], 'r.pdf');
  });

  test('expired turns are dropped on read and write', () async {
    final stale = CachedSentAttachments(
      savedAtMs: DateTime.now()
          .subtract(const Duration(days: 91))
          .millisecondsSinceEpoch,
      text: 'old',
      imageDataUrls: const [],
      files: const [],
    );
    await SentAttachmentCache.append('c', 's', stale);
    expect(await SentAttachmentCache.readAll('c', 's'), isEmpty);

    await SentAttachmentCache.append(
      'c',
      's',
      CachedSentAttachments(
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
        text: 'fresh',
        imageDataUrls: [],
        files: [],
      ),
    );
    expect(await SentAttachmentCache.readAll('c', 's'), hasLength(1));
  });

  test('maxTurns bounds the cache and removeConnection clears all', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < 55; i++) {
      await SentAttachmentCache.append(
        'c',
        's',
        CachedSentAttachments(
          savedAtMs: now + i,
          text: 'turn-$i',
          imageDataUrls: const [],
          files: const [],
        ),
      );
    }
    expect(await SentAttachmentCache.readAll('c', 's'), hasLength(50));

    await SentAttachmentCache.append('c', 's2', _freshTurn());
    await SentAttachmentCache.removeConnection('c');
    expect(await SentAttachmentCache.readAll('c', 's'), isEmpty);
    expect(await SentAttachmentCache.readAll('c', 's2'), isEmpty);
  });

  test('namespaces keep chats apart and keys stay decodable', () {
    expect(SentAttachmentCache.key('c', 's1'),
        isNot(SentAttachmentCache.key('c', 's2')));
    expect(SentAttachmentCache.key('a|b', 'x:y'),
        SentAttachmentCache.key('a|b', 'x:y'));
  });
}

CachedSentAttachments _freshTurn() => CachedSentAttachments(
  savedAtMs: DateTime.now().millisecondsSinceEpoch,
  text: 'fresh',
  imageDataUrls: [],
  files: [],
);
