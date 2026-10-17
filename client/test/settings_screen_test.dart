import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings reads the app root (`HermesAppState`) for the text-size and theme
/// controls, so it is opened the way the app opens it: on top of the real root.
Future<void> _openSettings(
  WidgetTester tester,
  SavedConnection connection, {
  Size size = const Size(400, 1800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(HermesApp(connManager: ConnectionManager(prefs)));
  await tester.pumpAndSettle();

  Navigator.of(tester.element(find.text('No connections'))).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(connection: connection),
    ),
  );
  await _settle(tester);
}

/// The voice list waits for a platform channel that never answers in a test, so its
/// spinner runs forever: pumpAndSettle would never return.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// HTTPS behind a path prefix and no dashboard: the Gateway API only.
SavedConnection _gatewayOnly() => SavedConnection(
  id: 'lean',
  label: 'Lean server',
  host: 'hermes.example.test',
  port: 443,
  apiKey: 'key',
  useHttps: true,
  gatewayPrefix: '/hermes',
);

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('a connection with only the Gateway API', () {
    testWidgets('has no model section and no note about a missing dashboard', (
      tester,
    ) async {
      await _openSettings(tester, _gatewayOnly());

      expect(find.text(l10n.profile_default_model), findsNothing);
      expect(find.text(l10n.set_profile_default), findsNothing);
      expect(find.textContaining('dashboard'), findsNothing);
      expect(find.text(l10n.appearance), findsOneWidget);
    });

    testWidgets('still offers the settings of the phone', (tester) async {
      await _openSettings(tester, _gatewayOnly());

      for (final header in [
        l10n.appearance,
        l10n.notifications,
        l10n.voice,
        l10n.connection_section,
      ]) {
        await tester.scrollUntilVisible(
          find.text(header),
          200,
          scrollable: find.byType(Scrollable).first,
          duration: const Duration(milliseconds: 100),
        );
        expect(find.text(header), findsOneWidget, reason: header);
      }
    });
  });

  group('every connection', () {
    testWidgets('has no "Session sources" section: nothing reads it', (
      tester,
    ) async {
      await _openSettings(tester, _gatewayOnly());

      expect(find.text('Session Sources'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
    });

    testWidgets('has a theme switch of three plain, one-line segments', (
      tester,
    ) async {
      await _openSettings(tester, _gatewayOnly());

      final switcher = find.byType(SegmentedButton<String>);
      expect(switcher, findsOneWidget);
      for (final label in [l10n.system, l10n.dark, l10n.light]) {
        expect(
          find.descendant(of: switcher, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(of: switcher, matching: find.byType(Icon)),
        findsNothing,
        reason: 'icons and a check mark made the labels wrap on a phone',
      );
    });

    testWidgets('keeps the theme switch on one line on the narrowest phone', (
      tester,
    ) async {
      await _openSettings(tester, _gatewayOnly(), size: const Size(320, 1800));

      for (final label in [l10n.system, l10n.dark, l10n.light]) {
        final text = tester.getSize(find.text(label));
        expect(text.height, lessThan(24), reason: '$label must not wrap');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('has a chat background switch: on at first, and remembered', (
      tester,
    ) async {
      await _openSettings(tester, _gatewayOnly());

      final tile = find.widgetWithText(SwitchListTile, l10n.chat_wallpaper);
      expect(tile, findsOneWidget);
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);

      await tester.tap(tile);
      await _settle(tester);

      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('chat_wallpaper'), isFalse);
    });

    testWidgets('choosing a theme is remembered', (tester) async {
      await _openSettings(tester, _gatewayOnly());

      await tester.tap(find.text(l10n.dark));
      await _settle(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_mode'), 'dark');
    });
  });
}
