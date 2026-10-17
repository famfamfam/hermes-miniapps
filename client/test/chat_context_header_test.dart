import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/chat_context_header.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Future<void> _pump(
  WidgetTester tester, {
  String? projectName,
  bool showProject = true,
  String reasoning = 'high',
  String connection = 'Miniserver',
  ChatConnectionStatus status = ChatConnectionStatus.connected,
  Size size = const Size(400, 800),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: hermesTheme(Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Chat'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: ChatContextHeader(
                projectName: projectName,
                showProject: showProject,
                reasoningEffort: reasoning,
                connectionLabel: connection,
                connectionStatus: status,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

bool _hasContent({
  String? projectName,
  bool showProject = true,
  String reasoning = 'default',
  ChatConnectionStatus status = ChatConnectionStatus.connected,
}) => ChatContextHeader.hasContent(
  projectName: projectName,
  showProject: showProject,
  reasoningEffort: reasoning,
  connectionStatus: status,
);

void main() {
  testWidgets('shows the project and a chosen reasoning effort', (
    tester,
  ) async {
    await _pump(tester, projectName: 'Hermes Android');

    expect(find.text('Hermes Android'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
  });

  testWidgets('does not repeat the model: the composer carries it', (
    tester,
  ) async {
    await _pump(tester, projectName: 'Hermes Android');

    expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
  });

  testWidgets('a healthy connection is not a chip', (tester) async {
    await _pump(tester, projectName: 'Hermes Android');

    expect(find.text('Miniserver'), findsNothing);
    expect(find.byIcon(Icons.circle), findsNothing);
  });

  testWidgets('labels a chat without a known project as Unassigned', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Unassigned'), findsOneWidget);
  });

  testWidgets('a connection with no Projects does not label chats Unassigned', (
    tester,
  ) async {
    await _pump(tester, showProject: false);

    expect(find.text('Unassigned'), findsNothing);
    expect(find.byIcon(Icons.folder_outlined), findsNothing);
  });

  testWidgets('a known project is shown even where Projects are not offered', (
    tester,
  ) async {
    await _pump(tester, projectName: 'Carried over', showProject: false);

    expect(find.text('Carried over'), findsOneWidget);
  });

  testWidgets('"default" reasoning is not a chip', (tester) async {
    await _pump(tester, reasoning: 'default');

    expect(find.text('default'), findsNothing);
    expect(find.byIcon(Icons.psychology_outlined), findsNothing);
  });

  testWidgets('"none" is shown as off, not as nothing', (tester) async {
    await _pump(tester, reasoning: 'none');

    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('exposes the offline state accessibly', (tester) async {
    await _pump(tester, status: ChatConnectionStatus.offline);

    expect(find.text('Miniserver'), findsOneWidget);
    expect(find.bySemanticsLabel('Miniserver offline'), findsOneWidget);
  });

  testWidgets('a reconnecting connection is shown, a connecting one is not', (
    tester,
  ) async {
    await _pump(tester, status: ChatConnectionStatus.reconnecting);
    expect(find.bySemanticsLabel('Miniserver reconnecting'), findsOneWidget);

    await _pump(tester, status: ChatConnectionStatus.connecting);
    expect(find.bySemanticsLabel('Miniserver connecting'), findsNothing);
  });

  testWidgets('survives narrow width and large text', (tester) async {
    await _pump(
      tester,
      projectName: 'A very long Project name that must not overflow',
      status: ChatConnectionStatus.offline,
      size: const Size(320, 640),
      textScale: 1.8,
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(ChatContextHeader), findsOneWidget);
  });

  group('hasContent', () {
    test('is false when there is nothing worth showing', () {
      expect(_hasContent(showProject: false), isFalse);
    });

    test('is true for a project, a chosen effort, or a dropped connection', () {
      expect(_hasContent(), isTrue, reason: 'Projects offered: Unassigned');
      expect(_hasContent(showProject: false, projectName: 'P'), isTrue);
      expect(_hasContent(showProject: false, reasoning: 'high'), isTrue);
      expect(
        _hasContent(showProject: false, status: ChatConnectionStatus.offline),
        isTrue,
      );
      expect(
        _hasContent(
          showProject: false,
          status: ChatConnectionStatus.reconnecting,
        ),
        isTrue,
      );
    });

    test('a connection that is only starting does not make a bar appear', () {
      expect(
        _hasContent(
          showProject: false,
          status: ChatConnectionStatus.connecting,
        ),
        isFalse,
      );
    });
  });
}
