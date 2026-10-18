// The application's side of file transfer for mini-apps: what the system picker is asked for, the three-action sheet,
// and what each action does with a received file.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/android_file_actions.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';

final bytes = Uint8List.fromList(List.generate(2048, (i) => i % 251));

void main() {
  group('the picker filter', () {
    test('nothing listed, or anything it cannot express, is no filter', () {
      expect(pickerFilterFor(const []), const PickerFilter(FileType.any));
      expect(
        pickerFilterFor(const ['video/*']),
        const PickerFilter(FileType.any),
      );
      expect(pickerFilterFor(const ['*/*']), const PickerFilter(FileType.any));
      expect(
        pickerFilterFor(const ['application/pdf', 'video/mp4']),
        const PickerFilter(FileType.any),
      );
    });

    test('images are the system image picker', () {
      expect(
        pickerFilterFor(const ['image/*']),
        const PickerFilter(FileType.image),
      );
    });

    test('known media types and extensions become a list of extensions', () {
      expect(
        pickerFilterFor(const ['application/pdf']),
        const PickerFilter(FileType.custom, ['pdf']),
      );
      expect(
        pickerFilterFor(const ['image/jpeg', 'application/pdf']),
        const PickerFilter(FileType.custom, ['jpeg', 'jpg', 'pdf']),
      );
      expect(
        pickerFilterFor(const ['.CSV', 'text/plain']),
        const PickerFilter(FileType.custom, ['csv', 'txt']),
      );
    });

    test('a spreadsheet picker offers spreadsheets, whichever way it asks', () {
      expect(
        pickerFilterFor(const [
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ]),
        const PickerFilter(FileType.custom, ['xlsx']),
      );
      expect(
        pickerFilterFor(const [
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          'application/vnd.ms-excel',
          '.csv',
        ]),
        const PickerFilter(FileType.custom, ['csv', 'xls', 'xlsx']),
      );
    });
  });

  group('pick', () {
    BuildContext? context;
    Future<void> mount(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (c) {
              context = c;
              return const Scaffold();
            },
          ),
        ),
      );
    }

    testWidgets(
      'a chosen file becomes a stream the page never sees, with the picker asked for the right kind',
      (tester) async {
        await mount(tester);
        PickerFilter? asked;
        final actions = AndroidHostFileActions(
          pickFiles: (filter) async {
            asked = filter;
            return FilePickerResult([
              PlatformFile(
                name: 'a.pdf',
                size: 2048,
                readStream: Stream.value(bytes),
              ),
            ]);
          },
        );
        final picked = await actions.pick(
          context!,
          accept: const ['application/pdf'],
        );
        expect(asked, const PickerFilter(FileType.custom, ['pdf']));
        expect(picked!.name, 'a.pdf');
        expect(picked.length, 2048);
        expect(await picked.open().expand((c) => c).toList(), bytes);
      },
    );

    testWidgets('without a stream the file is read from its path', (
      tester,
    ) async {
      await mount(tester);
      final file = File(
        '${Directory.systemTemp.path}/pick_${DateTime.now().microsecondsSinceEpoch}.txt',
      )..writeAsBytesSync(bytes);
      addTearDown(file.deleteSync);
      final actions = AndroidHostFileActions(
        pickFiles: (_) async => FilePickerResult([
          PlatformFile(name: 'x.txt', size: 2048, path: file.path),
        ]),
      );
      final picked = await actions.pick(context!, accept: const []);
      expect(
        await tester.runAsync(() => picked!.open().expand((c) => c).toList()),
        bytes,
      );
    });

    testWidgets(
      'a closed picker, an empty result and a file with no way to read it give nothing',
      (tester) async {
        await mount(tester);
        expect(
          await AndroidHostFileActions(
            pickFiles: (_) async => null,
          ).pick(context!, accept: const []),
          isNull,
        );
        expect(
          await AndroidHostFileActions(
            pickFiles: (_) async => FilePickerResult(const []),
          ).pick(context!, accept: const []),
          isNull,
        );
        expect(
          await AndroidHostFileActions(
            pickFiles: (_) async =>
                FilePickerResult([PlatformFile(name: 'x', size: 1)]),
          ).pick(context!, accept: const []),
          isNull,
        );
      },
    );
  });

  group('the sheet', () {
    late Directory cache;
    late List<MethodCall> channelCalls;
    late Object? channelAnswer;
    const channel = MethodChannel('test/files');
    String? savedName;
    Uint8List? savedBytes;
    String? sharedPath;
    String? sharedMime;
    Future<String?> Function(String, Uint8List)? saveBehaviour;
    BuildContext? context;

    setUp(() {
      cache = Directory.systemTemp.createTempSync('offer');
      channelCalls = [];
      channelAnswer = true;
      savedName = null;
      savedBytes = null;
      sharedPath = null;
      sharedMime = null;
      saveBehaviour = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            channelCalls.add(call);
            if (channelAnswer is Exception) throw channelAnswer! as Exception;
            return channelAnswer;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      cache.deleteSync(recursive: true);
    });

    AndroidHostFileActions actions() => AndroidHostFileActions(
      channel: channel,
      temporaryDirectory: () async => cache,
      saveFile: (name, data) async {
        savedName = name;
        savedBytes = data;
        return saveBehaviour == null
            ? '/storage/emulated/0/Download/$name'
            : saveBehaviour!(name, data);
      },
      share: (path, name, mime) async {
        sharedPath = path;
        sharedMime = mime;
      },
    );

    Future<void> mount(
      WidgetTester tester, {
      Locale locale = const Locale('en'),
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (c) {
              context = c;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
    }

    Future<FileOfferResult> offerAndTap(
      WidgetTester tester,
      AndroidHostFileActions a,
      String? tapKey, {
      String name = 'Квитанция.pdf',
      String mime = 'application/pdf',
    }) async {
      late Future<FileOfferResult> pending;
      await tester.runAsync(() async {
        pending = a.offer(context!, name: name, mime: mime, bytes: bytes);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      if (tapKey == null) {
        await tester.tapAt(
          const Offset(10, 10),
        ); // the barrier: dismiss the sheet
      } else {
        await tester.tap(find.byKey(Key(tapKey)));
      }
      await tester.pumpAndSettle();
      final result = (await tester.runAsync(() => pending))!;
      await tester.pump(); // the snack bar of the outcome, if any
      await tester.pump(const Duration(milliseconds: 100));
      return result;
    }

    testWidgets(
      'names the file and offers exactly three actions, in the viewer\'s language',
      (tester) async {
        await mount(tester);
        late Future<FileOfferResult> pending;
        await tester.runAsync(() async {
          pending = actions().offer(
            context!,
            name: 'Квитанция.pdf',
            mime: 'application/pdf',
            bytes: bytes,
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(find.text('Квитанция.pdf'), findsOneWidget);
        expect(find.text('2 KB · application/pdf'), findsOneWidget);
        expect(find.byType(ListTile), findsNWidgets(3));
        expect(find.text('Save to this phone'), findsOneWidget);
        expect(find.text('Open'), findsOneWidget);
        expect(find.text('Share'), findsOneWidget);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(await tester.runAsync(() => pending), FileOfferResult.cancelled);
        expect(savedName, isNull);
        expect(channelCalls, isEmpty);
        expect(sharedPath, isNull);
      },
    );

    testWidgets('the sheet speaks Russian on a Russian phone', (tester) async {
      await mount(tester, locale: const Locale('ru'));
      await tester.runAsync(() async {
        actions().offer(
          context!,
          name: 'a.pdf',
          mime: 'application/pdf',
          bytes: bytes,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Сохранить на телефон'), findsOneWidget);
      expect(find.text('Открыть'), findsOneWidget);
      expect(find.text('Поделиться'), findsOneWidget);
    });

    testWidgets('Save hands the bytes to the system save dialog and says so', (
      tester,
    ) async {
      await mount(tester);
      final result = await offerAndTap(tester, actions(), 'file-offer-save');
      expect(result, FileOfferResult.saved);
      expect(savedName, 'Квитанция.pdf');
      expect(savedBytes, bytes);
      expect(find.text('Saved Квитанция.pdf'), findsOneWidget);
    });

    testWidgets('a closed save dialog is a cancellation, not a success', (
      tester,
    ) async {
      await mount(tester);
      saveBehaviour = (_, _) async => null;
      expect(
        await offerAndTap(tester, actions(), 'file-offer-save'),
        FileOfferResult.cancelled,
      );
      expect(find.textContaining('Saved'), findsNothing);
    });

    testWidgets(
      'Open copies the file into the provider\'s folder and asks the platform to show that copy',
      (tester) async {
        await mount(tester);
        final result = await offerAndTap(
          tester,
          actions(),
          'file-offer-open',
          name: '../../etc/evil name.pdf',
        );
        expect(result, FileOfferResult.opened);
        final call = channelCalls.single;
        expect(call.method, 'openFile');
        final path = (call.arguments as Map)['path'] as String;
        expect((call.arguments as Map)['mime'], 'application/pdf');
        expect(
          path.replaceAll('\\', '/'),
          startsWith('${cache.path.replaceAll('\\', '/')}/opened_files/'),
        );
        expect(path, contains('evil name.pdf'));
        expect(path, isNot(contains('..')));
        expect(File(path).readAsBytesSync(), bytes);
      },
    );

    testWidgets(
      'no app to open the file says so and offers nothing else on its own',
      (tester) async {
        await mount(tester);
        channelAnswer = false;
        expect(
          await offerAndTap(tester, actions(), 'file-offer-open'),
          FileOfferResult.cancelled,
        );
        expect(
          find.text(
            'No app on this phone can open this file. Save or share it instead.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('a platform that has no such channel says so the same way', (
      tester,
    ) async {
      await mount(tester);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(
        await offerAndTap(tester, actions(), 'file-offer-open'),
        FileOfferResult.cancelled,
      );
      expect(
        find.text(
          'No app on this phone can open this file. Save or share it instead.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'a failure while preparing the file is reported, not thrown at the page',
      (tester) async {
        await mount(tester);
        channelAnswer = PlatformException(code: 'x');
        expect(
          await offerAndTap(tester, actions(), 'file-offer-open'),
          FileOfferResult.cancelled,
        );
        expect(
          find.text('That did not work. Try again or choose another action.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Share gives the system share sheet a copy with the right type',
      (tester) async {
        await mount(tester);
        expect(
          await offerAndTap(tester, actions(), 'file-offer-share'),
          FileOfferResult.shared,
        );
        expect(sharedMime, 'application/pdf');
        expect(File(sharedPath!).readAsBytesSync(), bytes);
        expect(sharedPath!.replaceAll('\\', '/'), contains('/opened_files/'));
      },
    );

    testWidgets(
      'earlier copies are cleared after a day; recent ones and the folder\'s neighbours stay',
      (tester) async {
        await mount(tester);
        final folder = Directory('${cache.path}/opened_files')..createSync();
        final stale = File('${folder.path}/old.pdf')..writeAsBytesSync([1]);
        stale.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 2)),
        );
        final fresh = File('${folder.path}/recent.pdf')..writeAsBytesSync([2]);
        final neighbour = File('${cache.path}/other.pdf')
          ..writeAsBytesSync([3]);
        neighbour.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 9)),
        );
        await offerAndTap(tester, actions(), 'file-offer-share');
        expect(stale.existsSync(), isFalse);
        expect(fresh.existsSync(), isTrue);
        expect(
          neighbour.existsSync(),
          isTrue,
          reason: 'only the provider\'s folder is ever touched',
        );
      },
    );
  });
}
