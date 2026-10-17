import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/screens/workspace_sessions_screen.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Session _session(String id, String title) => Session(
  id: id,
  title: title,
  model: 'synthetic-model',
  source: 'gateway',
  messageCount: 1,
  isActive: false,
  preview: '',
  startedAt: 1750000000,
  lastActive: 1750000000,
);

void main() {
  late List<String> deleted;
  late List<String> opened;

  Future<void> pump(
    WidgetTester tester, {
    Future<void> Function(Session)? onDelete,
    bool withDelete = true,
  }) async {
    deleted = [];
    opened = [];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: hermesTheme(Brightness.dark),
        home: Scaffold(
          body: WorkspaceSessionsScreen(
            title: 'Chats',
            view: WorkspaceSessionView.all,
            embedded: true,
            load: () async => WorkspaceSessionsData(
              sessions: [
                _session('s1', 'Alpha'),
                _session('s2', 'Beta'),
                _session('s3', 'Gamma'),
              ],
            ),
            onOpenSession: (session) => opened.add(session.id),
            onDelete: withDelete
                ? (onDelete ?? (session) async => deleted.add(session.id))
                : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('confirm-delete-chats')));
    await tester.pumpAndSettle();
  }

  testWidgets('the row menu deletes one chat after a confirmation', (
    tester,
  ) async {
    await pump(tester);
    final menu = find.descendant(
      of: find
          .ancestor(of: find.text('Alpha'), matching: find.byType(Row))
          .first,
      matching: find.byTooltip('Chat actions'),
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete chat'));
    await tester.pumpAndSettle();
    expect(find.text('Delete session?'), findsOneWidget);
    expect(deleted, isEmpty, reason: 'nothing is deleted before confirming');

    await confirm(tester);
    expect(deleted, ['s1']);
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Session deleted from remote Hermes.'), findsOneWidget);
  });

  testWidgets('cancelling the confirmation deletes nothing', (tester) async {
    await pump(tester);
    await tester.longPress(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Selected: 1'), findsOneWidget);
  });

  testWidgets(
    'long press starts selection, taps toggle rows, one confirmation deletes all',
    (tester) async {
      await pump(tester);
      await tester.longPress(find.text('Alpha'));
      await tester.pump();
      expect(find.byKey(const Key('chat-selection-bar')), findsOneWidget);
      expect(find.text('Selected: 1'), findsOneWidget);

      await tester.tap(find.text('Gamma'));
      await tester.pump();
      expect(find.text('Selected: 2'), findsOneWidget);
      expect(opened, isEmpty, reason: 'a tap selects instead of opening');

      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete chats: 2?'), findsOneWidget);
      await confirm(tester);

      expect(deleted, ['s1', 's3']);
      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Gamma'), findsNothing);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.byKey(const Key('chat-selection-bar')), findsNothing);
      expect(find.text('Chats deleted: 2'), findsOneWidget);

      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(opened, ['s2'], reason: 'selection mode ended, taps open again');
    },
  );

  testWidgets('select all picks every visible chat', (tester) async {
    await pump(tester);
    await tester.longPress(find.text('Alpha'));
    await tester.pump();
    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('Selected: 3'), findsOneWidget);
  });

  testWidgets('a failed delete keeps that chat listed and selected', (
    tester,
  ) async {
    await pump(
      tester,
      onDelete: (session) async {
        if (session.id == 's2') throw Exception('synthetic 500');
        deleted.add(session.id);
      },
    );
    await tester.longPress(find.text('Alpha'));
    await tester.pump();
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await confirm(tester);

    expect(deleted, ['s1']);
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Selected: 1'), findsOneWidget);
    expect(find.text('Not deleted: 1. Try again later.'), findsOneWidget);
  });

  testWidgets('Back leaves selection mode instead of the screen', (
    tester,
  ) async {
    await pump(tester);
    await tester.longPress(find.text('Alpha'));
    await tester.pump();
    expect(find.byKey(const Key('chat-selection-bar')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-selection-bar')), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('without a delete handler there is no selection or delete item', (
    tester,
  ) async {
    await pump(tester, withDelete: false);
    await tester.longPress(find.text('Alpha'));
    await tester.pump();
    expect(find.byKey(const Key('chat-selection-bar')), findsNothing);
    expect(find.text('Delete chat'), findsNothing);
  });
}
