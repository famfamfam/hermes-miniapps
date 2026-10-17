import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/services/remote_files_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/utils/media_tags.dart';
import 'package:hermes_android/core/widgets/media_artifact_card.dart';

import 'support/fake_voice_composer_adapter.dart';

List<String> render(List<MediaTextSegment> segments) =>
    segments.map((s) => s.isMedia ? 'CARD:${s.media!.path}' : s.text).toList();

class _FakeFiles implements RemoteFilesDataSource {
  final Map<String, List<int>> files;
  final List<String> requested = [];
  _FakeFiles(this.files);

  @override
  Future<RemoteDirectory> defaultDirectory() async =>
      throw UnimplementedError();

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async =>
      throw UnimplementedError();

  @override
  Future<RemoteTextPreview> readText(String path) async =>
      throw UnimplementedError();

  @override
  Future<RemoteFileDownload> download(String path) async {
    requested.add(path);
    final bytes = files[path];
    if (bytes == null) throw Exception('no such file: $path');
    return RemoteFileDownload(filename: path.split('/').last, bytes: bytes);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  group('splitMediaTags (cards only for standalone-line refs)', () {
    test('plain text passes through untouched', () {
      expect(render(splitMediaTags('nothing here')), ['nothing here']);
    });

    test('tag alone on its line becomes a card and consumes the line', () {
      expect(
        render(splitMediaTags('Here you go:\nMEDIA:/home/jon/out.png\nbye')),
        ['Here you go:\n', 'CARD:/home/jon/out.png', 'bye'],
      );
    });

    test('mid-line tag stays prose (rendered later as an inline link)', () {
      expect(
        render(
          splitMediaTags('Here is the chart MEDIA:/home/jon/out.png done'),
        ),
        ['Here is the chart MEDIA:/home/jon/out.png done'],
      );
    });

    test('trailing punctuation on a standalone tag sheds into prose', () {
      expect(render(splitMediaTags('MEDIA:/tmp/a.pdf.')), [
        'CARD:/tmp/a.pdf',
        '.',
      ]);
    });

    test('degenerate captures stay prose', () {
      expect(render(splitMediaTags('MEDIA:...')), ['MEDIA:...']);
      expect(render(splitMediaTags('MEDIA:stuff')), ['MEDIA:stuff']);
      expect(render(splitMediaTags("MEDIA:'", isFinal: false)), ["MEDIA:'"]);
      expect(render(splitMediaTags("MEDIA:'")), ["MEDIA:'"]);
    });

    test('quoted capture keeps interior spaces and punctuation', () {
      expect(render(splitMediaTags('MEDIA:"/tmp/my file.png"')), [
        'CARD:/tmp/my file.png',
      ]);
      expect(render(splitMediaTags("MEDIA:'/tmp/stop!.md'")), [
        'CARD:/tmp/stop!.md',
      ]);
      expect(render(splitMediaTags('MEDIA:`/tmp/backtick file.png`')), [
        'CARD:/tmp/backtick file.png',
      ]);
    });

    test('multiple standalone refs each become a card', () {
      expect(render(splitMediaTags('MEDIA:/a.png\nMEDIA:/b.pdf')), [
        'CARD:/a.png',
        'CARD:/b.pdf',
      ]);
    });

    test('streaming partial at end of text stays prose', () {
      // Mid-token: the next delta could extend the path.
      expect(render(splitMediaTags('here MEDIA:/home/jon/repo')), [
        'here MEDIA:/home/jon/repo',
      ]);
    });

    test('completed path at end of text converts to a card', () {
      expect(render(splitMediaTags('here:\nMEDIA:/home/jon/report.pdf')), [
        'here:\n',
        'CARD:/home/jon/report.pdf',
      ]);
    });

    test('unknown-extension and extensionless paths wait for final state', () {
      for (final path in ['/tmp/script.py', '/tmp/Caddyfile']) {
        expect(render(splitMediaTags('MEDIA:$path', isFinal: false)), [
          'MEDIA:$path',
        ]);
        expect(render(splitMediaTags('MEDIA:$path')), ['CARD:$path']);
      }
    });

    test('a closed quoted path is complete even while the reply streams', () {
      expect(render(splitMediaTags("MEDIA:'", isFinal: false)), ["MEDIA:'"]);
      expect(render(splitMediaTags("MEDIA:'/tmp/script.py", isFinal: false)), [
        "MEDIA:'/tmp/script.py",
      ]);
      expect(render(splitMediaTags("MEDIA:'/tmp/script.py'", isFinal: false)), [
        'CARD:/tmp/script.py',
      ]);
    });

    test('all Markdown code forms stay outside the MEDIA contract', () {
      final samples = [
        '`MEDIA:/tmp/inline.png`',
        '``MEDIA:/tmp/inline`tick.png``',
        '```md\nMEDIA:/tmp/backtick.png\n```',
        '````md\nMEDIA:/tmp/long-fence.png\n````',
        '~~~md\nMEDIA:/tmp/tilde.png\n~~~',
        '```dart title="example" {.numberLines}\n'
            'MEDIA:/tmp/metadata.png\n```',
        '    MEDIA:/tmp/indented.png',
        '\tMEDIA:/tmp/tab-indented.png',
        '~~~md\nMEDIA:/tmp/unclosed.png',
      ];
      for (final sample in samples) {
        expect(render(splitMediaTags(sample)), [sample], reason: sample);
        expect(inlineMediaTagsAsLinks(sample), sample, reason: sample);
      }
    });

    test('a ref after protected Markdown code still becomes a card', () {
      const text =
          '~~~md\nMEDIA:/tmp/example.png\n~~~\n'
          'MEDIA:/tmp/result.png';
      expect(render(splitMediaTags(text)), [
        '~~~md\nMEDIA:/tmp/example.png\n~~~\n',
        'CARD:/tmp/result.png',
      ]);
    });

    test('windows and tilde anchors parse', () {
      expect(render(splitMediaTags(r'MEDIA:C:\out\chart.png')), [
        'CARD:C:\\out\\chart.png',
      ]);
      expect(render(splitMediaTags('MEDIA:~/docs/note.md')), [
        'CARD:~/docs/note.md',
      ]);
    });

    test('apostrophes stay inside bare paths', () {
      expect(render(splitMediaTags("MEDIA:/tmp/john's.md")), [
        "CARD:/tmp/john's.md",
      ]);
    });

    test('uppercase extension parses (guard and pattern agree)', () {
      expect(render(splitMediaTags('MEDIA:/tmp/x.PNG')), ['CARD:/tmp/x.PNG']);
    });

    test(
      'gateway ext parity: archives/geo/presentations card at end of text',
      () {
        // The wire-contract audit found the Dart ext list had drifted 18 exts
        // behind the gateway's MEDIA_DELIVERY_EXTS; a missing ext silently
        // drops the card when the tag ends the message (streaming guard).
        for (final path in [
          '/data/archive.zip',
          '/data/bundle.tar.gz',
          '/data/layer.kml',
          '/data/site.geojson',
          '/deck.pptx',
          '/cfg/settings.yaml',
        ]) {
          expect(
            render(splitMediaTags('MEDIA:$path')),
            ['CARD:$path'],
            reason: 'missing gateway ext for $path',
          );
        }
      },
    );
  });

  group('inlineMediaTagsAsLinks', () {
    test('mid-line ref becomes a markdown link with the basename label', () {
      expect(
        inlineMediaTagsAsLinks('see MEDIA:/tmp/report.pdf ok'),
        'see [report.pdf](media-artifact:///tmp/report.pdf) ok',
      );
    });

    test('degenerate captures are left alone', () {
      expect(inlineMediaTagsAsLinks('MEDIA:stuff'), 'MEDIA:stuff');
    });

    test('streaming partial at end of text is not linked', () {
      expect(
        inlineMediaTagsAsLinks('see MEDIA:/tmp/repo', isFinal: false),
        'see MEDIA:/tmp/repo',
      );
    });

    test('final unknown-extension inline ref becomes a link', () {
      expect(
        inlineMediaTagsAsLinks('see MEDIA:/tmp/script.py'),
        'see [script.py](media-artifact:///tmp/script.py)',
      );
    });

    test('artifact href decoding is lossless and malformed input is inert', () {
      const path = '/tmp/a #100%?.pdf';
      final markdown = inlineMediaTagsAsLinks('see MEDIA:"$path" now');
      final href = RegExp(
        r'\((media-artifact://[^)]+)\)',
      ).firstMatch(markdown)![1]!;
      expect(mediaPathFromArtifactHref(href), path);
      expect(mediaPathFromArtifactHref('media-artifact://%ZZ'), isNull);
      expect(mediaPathFromArtifactHref('media-artifact://word'), isNull);
    });
  });

  group('MessageBubble media rendering', () {
    Future<void> pumpBubble(
      WidgetTester tester, {
      required String content,
      required bool isUser,
      RemoteFilesDataSource Function()? filesClient,
      bool referencesFinal = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MessageBubble(
              content: content,
              isUser: isUser,
              mediaFilesClient: filesClient,
              mediaReferencesFinal: referencesFinal,
            ),
          ),
        ),
      );
    }

    testWidgets('standalone ref renders a card, prose stays markdown', (
      tester,
    ) async {
      final files = _FakeFiles({
        '/out/report.pdf': [1, 2, 3],
      });
      await pumpBubble(
        tester,
        content: 'Done.\nMEDIA:/out/report.pdf',
        isUser: false,
        filesClient: () => files,
      );
      expect(find.byKey(Key('media-card-/out/report.pdf')), findsOneWidget);
      expect(find.textContaining('Done.'), findsOneWidget);
    });

    testWidgets('mid-line ref stays inline and is tappable', (tester) async {
      final files = _FakeFiles({
        '/out/a.png': [1],
      });
      await pumpBubble(
        tester,
        content: '- fetch the chart MEDIA:/out/a.png and open it',
        isUser: false,
        filesClient: () => files,
      );
      expect(find.byType(MediaArtifactCard), findsNothing);
      await tester.tap(find.textContaining('a.png', findRichText: true));
      await tester.pump();
      expect(files.requested, ['/out/a.png']);
    });

    testWidgets('streaming unknown path becomes a card only when final', (
      tester,
    ) async {
      final files = _FakeFiles({
        '/tmp/script.py': [1],
      });
      await pumpBubble(
        tester,
        content: 'MEDIA:/tmp/script.py',
        isUser: false,
        filesClient: () => files,
        referencesFinal: false,
      );
      expect(find.byType(MediaArtifactCard), findsNothing);

      await pumpBubble(
        tester,
        content: 'MEDIA:/tmp/script.py',
        isUser: false,
        filesClient: () => files,
      );
      expect(
        find.byKey(const Key('media-card-/tmp/script.py')),
        findsOneWidget,
      );
    });

    testWidgets('MEDIA: inside a closed code fence stays verbatim', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        content: 'example:\n```\nMEDIA:/fake.png\n```\nend',
        isUser: false,
        filesClient: () => _FakeFiles({}),
      );
      expect(find.byType(MediaArtifactCard), findsNothing);
    });

    testWidgets('MEDIA: inside an UNCLOSED fence (streaming) leaks no card', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        content: 'doc:\n```md\nMEDIA:/tmp/example.png',
        isUser: false,
        filesClient: () => _FakeFiles({}),
      );
      expect(find.byType(MediaArtifactCard), findsNothing);
    });

    testWidgets('tilde, metadata, indented, and inline code stay inert', (
      tester,
    ) async {
      final files = _FakeFiles({
        '/tmp/example.png': [1],
      });
      for (final content in [
        '~~~md\nMEDIA:/tmp/example.png\n~~~',
        '```dart title="example" {.numberLines}\n'
            'MEDIA:/tmp/example.png\n```',
        '    MEDIA:/tmp/example.png',
        '\tMEDIA:/tmp/example.png',
        '`MEDIA:/tmp/example.png`',
      ]) {
        await pumpBubble(
          tester,
          content: content,
          isUser: false,
          filesClient: () => files,
        );
        expect(find.byType(MediaArtifactCard), findsNothing, reason: content);
      }
      expect(files.requested, isEmpty);
    });

    testWidgets('user bubbles never parse refs', (tester) async {
      await pumpBubble(
        tester,
        content: 'Done.\nMEDIA:/out/report.pdf',
        isUser: true,
        filesClient: () => _FakeFiles({}),
      );
      expect(find.byType(MediaArtifactCard), findsNothing);
    });

    testWidgets('no files client leaves refs as prose', (tester) async {
      await pumpBubble(
        tester,
        content: 'Done.\nMEDIA:/out/report.pdf',
        isUser: false,
      );
      expect(find.byType(MediaArtifactCard), findsNothing);
    });

    testWidgets('crafted artifact link without a files client is inert', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        content: '[open](media-artifact:///tmp/a.pdf)',
        isUser: false,
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('tap downloads via the exact ref path', (tester) async {
      final files = _FakeFiles({
        '/out/report.pdf': [1, 2, 3],
      });
      await pumpBubble(
        tester,
        content: 'MEDIA:/out/report.pdf',
        isUser: false,
        filesClient: () => files,
      );
      await tester.tap(find.byKey(Key('media-card-download-/out/report.pdf')));
      await tester.pump();
      // The share sheet is platform UI; assert only that the gateway fetch
      // fired for the exact ref path.
      expect(files.requested, ['/out/report.pdf']);
    });

    testWidgets('rapid repeated taps share one gateway download', (
      tester,
    ) async {
      final files = _FakeFiles({
        '/out/report.pdf': [1, 2, 3],
      });
      await pumpBubble(
        tester,
        content: 'MEDIA:/out/report.pdf',
        isUser: false,
        filesClient: () => files,
      );
      final download = find.byKey(
        const Key('media-card-download-/out/report.pdf'),
      );
      await tester.tap(download);
      await tester.tap(download);
      await tester.pump();
      expect(files.requested, ['/out/report.pdf']);
    });

    testWidgets('repeated refs receive occurrence-unique sibling keys', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        content: 'MEDIA:/out/report.pdf\nMEDIA:/out/report.pdf',
        isUser: false,
        filesClient: () => _FakeFiles({}),
      );
      final cards = tester.widgetList<MediaArtifactCard>(
        find.byType(MediaArtifactCard),
      );
      expect(cards, hasLength(2));
      expect(cards.map((card) => card.key).toSet(), hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'ref change resets card state (no stale bytes under new name)',
      (tester) async {
        final files = _FakeFiles({
          '/a/x.pdf': [1],
          '/b/y.pdf': [2],
        });
        await pumpBubble(
          tester,
          content: 'MEDIA:/a/x.pdf',
          isUser: false,
          filesClient: () => files,
        );
        await tester.tap(find.byKey(Key('media-card-download-/a/x.pdf')));
        await tester.pump();
        expect(files.requested, ['/a/x.pdf']);
        // Same position, different ref (streaming ref growth / recycling).
        await pumpBubble(
          tester,
          content: 'MEDIA:/b/y.pdf',
          isUser: false,
          filesClient: () => files,
        );
        await tester.pump();
        // The new card must not show a downloaded state from the old ref.
        expect(find.textContaining('Tap to download'), findsOneWidget);
      },
    );
  });

  testWidgets('ChatScreen binds artifact taps to the stored session key', (
    tester,
  ) async {
    final files = _FakeFiles({
      '/srv/result.pdf': [1],
    });
    String? capturedSessionId;
    final apiClient = ApiClient(
      baseUrl: 'http://chat.fixture',
      apiKey: '',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/sessions/mobile-draft/messages');
        return http.Response(
          jsonEncode({
            'data': [
              {'role': 'assistant', 'content': 'MEDIA:/srv/result.pdf'},
            ],
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(
          connection: SavedConnection(
            id: 'fixture',
            label: 'Fixture',
            host: 'chat.fixture',
            port: 8642,
            apiKey: '',
          ),
          session: const Session(
            id: 'mobile-draft',
            title: 'Artifacts',
            model: 'fixture',
            source: 'mobile',
            messageCount: 1,
            isActive: false,
            preview: '',
            startedAt: 1,
          ),
          testApiClient: apiClient,
          testStoredSessionKey: (_) => 'stored-session-42',
          testMediaFilesClient: (sessionId) {
            capturedSessionId = sessionId;
            return files;
          },
          testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('media-card-download-/srv/result.pdf')),
    );
    await tester.pump();

    expect(capturedSessionId, 'stored-session-42');
    expect(files.requested, ['/srv/result.pdf']);
  });
}
