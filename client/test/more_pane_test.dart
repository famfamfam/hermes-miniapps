import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/more_pane.dart';
import 'support/l10n_test_utils.dart';
import 'package:hermes_android/l10n/app_localizations.dart';


Future<void> _pumpPane(
  WidgetTester tester, {
  required List<MoreSection> sections,
  ValueChanged<MoreEntry>? onSelect,
  // Tall by default so assertions are about content, not scroll position; the
  // narrow-phone tests below set a real phone height explicitly.
  Size size = const Size(360, 1600),
  double textScale = 1.0,
  Brightness brightness = Brightness.dark,
  String? footnote,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: hermesTheme(brightness),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: MorePane(
              sections: sections,
              onSelect: onSelect ?? (_) {},
              footnote: footnote,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await loadTestL10n();
  });
  group('buildMoreSections', () {
    test('exposes every roadmap destination exactly once', () {
      final sections = buildMoreSections(dashboardReachable: true, l10n: l10n);
      final ids = [
        for (final section in sections)
          for (final entry in section.entries) entry.id,
      ];

      expect(ids.toSet(), hasLength(ids.length), reason: 'ids must be unique');
      expect(
        ids,
        containsAll(<String>[
          'files',
          'assets',
          'unassigned',
          'archived-quick',
          'cron',
          'skills',
          'memory',
          'settings',
          'dashboard',
        ]),
      );
    });

    test('Unassigned chats is not mislabeled as the action Inbox', () {
      final entry = buildMoreSections(dashboardReachable: true, l10n: l10n)
          .expand((section) => section.entries)
          .firstWhere((candidate) => candidate.id == 'unassigned');

      expect(entry.title, 'Unassigned chats');
      expect(entry.subtitle, contains('not assigned to a Project'));
    });

    test('every section has a title and at least one entry', () {
      for (final section in buildMoreSections(dashboardReachable: true, l10n: l10n)) {
        expect(section.title, isNotEmpty);
        expect(section.entries, isNotEmpty);
      }
    });

    test('dashboard-backed entries are available when the dashboard is', () {
      final entries = {
        for (final section in buildMoreSections(dashboardReachable: true, l10n: l10n))
          for (final entry in section.entries) entry.id: entry,
      };

      for (final id in ['cron', 'skills', 'memory', 'dashboard', 'settings']) {
        expect(
          entries[id]!.availability,
          MoreEntryAvailability.available,
          reason: '$id must be usable on a reachable dashboard',
        );
      }
    });

    test('a missing dashboard disables its entries with a reason', () {
      final entries = {
        for (final section in buildMoreSections(dashboardReachable: false, l10n: l10n))
          for (final entry in section.entries) entry.id: entry,
      };

      for (final id in ['cron', 'skills', 'memory', 'dashboard']) {
        final entry = entries[id]!;
        expect(
          entry.availability,
          MoreEntryAvailability.unavailable,
          reason: '$id needs the dashboard',
        );
        expect(
          entry.unavailableReason,
          isNotNull,
          reason: '$id must explain why it is disabled, not just grey out',
        );
        expect(entry.unavailableReason, isNotEmpty);
      }
    });

    test('local settings stay reachable without a dashboard', () {
      final entries = {
        for (final section in buildMoreSections(dashboardReachable: false, l10n: l10n))
          for (final entry in section.entries) entry.id: entry,
      };

      expect(
        entries['settings']!.availability,
        MoreEntryAvailability.available,
      );
    });

    test('contract-gated organization stays visible with exact reasons', () {
      final entries = {
        for (final section in buildMoreSections(dashboardReachable: true, l10n: l10n))
          for (final entry in section.entries) entry.id: entry,
      };

      for (final id in ['assets', 'pin-batch-undo', 'ai-filing']) {
        expect(entries[id]!.availability, MoreEntryAvailability.unavailable);
        expect(entries[id]!.unavailableReason, contains('Gateway'));
      }
    });

    test(
      'native Smart Views are available and only contract gaps are disabled',
      () {
        final entries = {
          for (final section in buildMoreSections(dashboardReachable: true, l10n: l10n))
            for (final entry in section.entries) entry.id: entry,
        };

        expect(entries['files']!.availability, MoreEntryAvailability.available);
        for (final id in ['unassigned', 'archived-quick']) {
          expect(entries[id]!.availability, MoreEntryAvailability.available);
        }
      },
    );

    test('Files follows the dashboard it depends on', () {
      final entries = {
        for (final section in buildMoreSections(dashboardReachable: false, l10n: l10n))
          for (final entry in section.entries) entry.id: entry,
      };

      expect(entries['files']!.availability, MoreEntryAvailability.unavailable);
      expect(entries['files']!.unavailableReason, isNotNull);
    });
  });

  group('MorePane', () {
    List<MoreSection> sections({bool dashboardReachable = true}) =>
        buildMoreSections(
          dashboardReachable: dashboardReachable,
          l10n: l10n,
        );

    testWidgets('renders every section title and entry', (tester) async {
      final built = sections();
      await _pumpPane(tester, sections: built);

      for (final section in built) {
        await tester.scrollUntilVisible(
          find.text(section.title),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(section.title), findsOneWidget);
      }
      await tester.scrollUntilVisible(
        find.text('Cron'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Cron'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Settings'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('selecting an available entry reports it once', (tester) async {
      final picked = <String>[];
      await _pumpPane(
        tester,
        sections: sections(),
        onSelect: (entry) => picked.add(entry.id),
      );

      await tester.ensureVisible(find.text('Cron'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cron'));
      await tester.pumpAndSettle();

      expect(picked, ['cron']);
    });

    testWidgets('an unavailable entry cannot be selected', (tester) async {
      final picked = <String>[];
      await _pumpPane(
        tester,
        sections: sections(dashboardReachable: false),
        onSelect: (entry) => picked.add(entry.id),
      );

      await tester.scrollUntilVisible(
        find.text('Cron'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Cron'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(picked, isEmpty);
    });

    testWidgets('an unavailable entry explains why on screen', (tester) async {
      final built = sections(dashboardReachable: false);
      await _pumpPane(tester, sections: built);

      final cron = built
          .expand((section) => section.entries)
          .firstWhere((entry) => entry.id == 'cron');

      expect(find.text(cron.unavailableReason!), findsWidgets);
    });

    testWidgets(
      'a contract-gated entry explains itself and is not selectable',
      (tester) async {
        final picked = <String>[];
        await _pumpPane(
          tester,
          sections: sections(),
          onSelect: (entry) => picked.add(entry.id),
        );

        await tester.tap(find.text('Assets'), warnIfMissed: false);
        await tester.pumpAndSettle();

        expect(
          find.textContaining('server-authoritative Assets index'),
          findsOneWidget,
        );
        expect(picked, isEmpty);
      },
    );

    testWidgets('survives a large text scale on a narrow phone', (
      tester,
    ) async {
      await _pumpPane(
        tester,
        sections: sections(),
        size: const Size(320, 640),
        textScale: 1.8,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Unassigned chats'), findsOneWidget);
    });

    testWidgets('scrolls to the last entry on a real phone height', (
      tester,
    ) async {
      await _pumpPane(tester, sections: sections(), size: const Size(360, 720));

      await tester.scrollUntilVisible(
        find.text('Settings'),
        160,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.text('Settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in the light theme', (tester) async {
      await _pumpPane(
        tester,
        sections: sections(),
        brightness: Brightness.light,
      );

      await tester.scrollUntilVisible(
        find.text('Settings'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('every entry is reachable by a screen reader', (tester) async {
      final built = sections();
      await _pumpPane(tester, sections: built);

      for (final section in built) {
        for (final entry in section.entries) {
          await tester.scrollUntilVisible(
            find.text(entry.title),
            120,
            scrollable: find.byType(Scrollable).first,
          );
          expect(
            find.bySemanticsLabel(RegExp(entry.title)),
            findsWidgets,
            reason: '${entry.title} must be announced',
          );
        }
      }
    });
  });

  group('the lean menu of a connection with only the Gateway API', () {
    test('keeps Settings and drops every entry that cannot work', () {
      final entries = [
        for (final section in buildMoreSections(
          dashboardReachable: false,
          lean: true,
          l10n: l10n,
        ))
          ...section.entries,
      ];

      expect([for (final entry in entries) entry.id], ['settings']);
      for (final entry in entries) {
        expect(
          entry.availability,
          MoreEntryAvailability.available,
          reason: 'nothing is listed greyed-out in the lean menu',
        );
      }
    });

    test('Apps and Tasks are tabs there, not menu entries', () {
      final ids = {
        for (final section in buildMoreSections(
          dashboardReachable: false,
          lean: true,
          l10n: l10n,
        ))
          for (final entry in section.entries) entry.id,
      };

      expect(ids.containsAll(['apps', 'cron']), isFalse);
    });

    test('the full menu is unchanged when lean is off', () {
      final lean = buildMoreSections(
        dashboardReachable: true,
        lean: false,
        l10n: l10n,
      );
      final plain = buildMoreSections(dashboardReachable: true, l10n: l10n);

      expect(
        [for (final s in lean) [for (final e in s.entries) e.id]],
        [for (final s in plain) [for (final e in s.entries) e.id]],
      );
    });

    testWidgets('renders Settings and one explanatory line, nothing disabled', (
      tester,
    ) async {
      await _pumpPane(
        tester,
        sections: buildMoreSections(
          dashboardReachable: false,
          lean: true,
          l10n: l10n,
        ),
        footnote: l10n.more_lean_note,
      );

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text(l10n.more_lean_note), findsOneWidget);
      expect(find.textContaining('Needs a reachable'), findsNothing);
      expect(find.text('Files'), findsNothing);
    });

    testWidgets('a footnote is optional', (tester) async {
      await _pumpPane(
        tester,
        sections: buildMoreSections(
          dashboardReachable: true,
          l10n: l10n,
        ),
      );

      expect(find.text(l10n.more_lean_note), findsNothing);
    });
  });
}
