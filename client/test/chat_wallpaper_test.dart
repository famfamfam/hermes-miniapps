// The hand-drawn wallpaper behind the chat: it draws, it has no seam where the tile repeats, it stays faint
// (one group alpha), it never takes a tap, and the chat shows it unless the Settings switch is off.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/chat_wallpaper.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const _darkSurface = Color(0xFF0E0E10);
const _lightSurface = Color(0xFFFAFAFA);

class _Pixels {
  _Pixels(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;

  int red(int x, int y) => rgba[(y * width + x) * 4];
}

/// Paints a [ChatWallpaper] on a flat surface of [width] x [height] logical pixels (one device pixel each).
Future<_Pixels> _paint(
  WidgetTester tester, {
  required bool dark,
  double? opacity,
  int width = 368,
  int height = 320,
}) async {
  tester.view.physicalSize = Size(width.toDouble(), height.toDouble());
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: dark ? _darkSurface : _lightSurface,
      ),
      home: Scaffold(
        body: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: width.toDouble(),
            height: height.toDouble(),
            child: ColoredBox(
              color: dark ? _darkSurface : _lightSurface,
              child: ChatWallpaper(opacity: opacity),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return _Pixels(image.width, image.height, data!.buffer.asUint8List());
  }))!;
}

int _surfaceRed(bool dark) =>
    ((dark ? _darkSurface : _lightSurface).r * 255).round();

int _maxRed(_Pixels px) {
  var best = 0;
  for (var i = 0; i < px.rgba.length; i += 4) {
    if (px.rgba[i] > best) best = px.rgba[i];
  }
  return best;
}

int _minRed(_Pixels px) {
  var best = 255;
  for (var i = 0; i < px.rgba.length; i += 4) {
    if (px.rgba[i] < best) best = px.rgba[i];
  }
  return best;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'verbose_mode': false}));

  group('the wallpaper', () {
    testWidgets('draws pencil lines, not a blank or a filled sheet', (
      tester,
    ) async {
      final px = await _paint(tester, dark: true, opacity: 1);
      final surface = _surfaceRed(true);
      var inked = 0;
      for (var i = 0; i < px.rgba.length; i += 4) {
        if (px.rgba[i] > surface + 40) inked++;
      }
      final total = px.width * px.height;
      expect(inked, greaterThan(total * 0.02), reason: 'drawings are there');
      expect(inked, lessThan(total * 0.25), reason: 'lines, not a fill');
    });

    testWidgets('is the same picture every time it is drawn', (tester) async {
      final first = await _paint(tester, dark: true, opacity: 1);
      await tester.pumpWidget(const SizedBox());
      final second = await _paint(tester, dark: true, opacity: 1);
      expect(second.rgba, first.rgba);
    });

    testWidgets('has no seam: a line that leaves the tile comes back in', (
      tester,
    ) async {
      final px = await _paint(tester, dark: true, opacity: 1);
      final surface = _surfaceRed(true);
      final last = px.width - 1;
      var crossing = 0;
      var unmatched = 0;
      for (var y = 0; y < px.height; y++) {
        if (px.red(last, y) <= surface + 90) continue;
        crossing++;
        final continues = [
          for (var dy = -3; dy <= 3; dy++)
            if (y + dy >= 0 && y + dy < px.height) px.red(0, y + dy),
        ].any((red) => red > surface + 40);
        if (!continues) unmatched++;
      }
      expect(
        crossing,
        greaterThan(3),
        reason: 'one drawing is placed across the edge of the tile on purpose',
      );
      expect(
        unmatched,
        lessThanOrEqualTo(crossing ~/ 10),
        reason: 'the part on the other side of the edge is drawn as well',
      );
    });

    testWidgets('stays faint: the whole pattern has one alpha', (tester) async {
      final px = await _paint(tester, dark: true);
      final surface = _surfaceRed(true);
      final ink = 0xF6;
      final ceiling =
          surface + ((ink - surface) * kDarkWallpaperOpacity).ceil();
      final brightest = _maxRed(px);
      expect(brightest, greaterThan(surface + 8), reason: 'visible at all');
      expect(
        brightest,
        lessThanOrEqualTo(ceiling + 2),
        reason: 'overlapping strokes must not add up to a brighter bead',
      );
    });

    testWidgets('is graphite on dark and sepia on light', (tester) async {
      final dark = await _paint(tester, dark: true);
      expect(_maxRed(dark), greaterThan(_surfaceRed(true) + 8));
      expect(_minRed(dark), greaterThanOrEqualTo(_surfaceRed(true)));
      await tester.pumpWidget(const SizedBox());
      final light = await _paint(tester, dark: false);
      expect(_minRed(light), lessThan(_surfaceRed(false) - 8));
      expect(_maxRed(light), lessThanOrEqualTo(_surfaceRed(false)));
    });

    testWidgets('lets taps through to what is underneath', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              Positioned.fill(
                child: TextButton(
                  onPressed: () => taps++,
                  child: const Text('under'),
                ),
              ),
              const Positioned.fill(child: ChatWallpaper()),
            ],
          ),
        ),
      );
      await tester.tap(find.text('under'));
      expect(taps, 1);
    });
  });

  group('the chat screen', () {
    Future<void> openChat(WidgetTester tester) async {
      final client = _EmptyServer();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChatScreen(
            connection: SavedConnection(
              id: 'wallpaper-test',
              label: 'Fixture',
              host: 'fixture.example',
              port: 8642,
              apiKey: 'synthetic-test-key',
            ),
            session: Session(
              id: 'wallpaper-session',
              title: 'Fixture chat',
              model: 'fixture-model',
              source: 'test',
              messageCount: 0,
              isActive: true,
              preview: '',
              startedAt: 1,
            ),
            testApiClient: ApiClient(
              baseUrl: 'http://fixture.example',
              apiKey: 'synthetic-test-key',
              httpClient: client,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('has the wallpaper behind the messages by default', (
      tester,
    ) async {
      await openChat(tester);

      expect(find.byType(ChatWallpaper), findsOneWidget);
      final wallpaper = tester.getRect(find.byType(ChatWallpaper));
      final list = tester.getRect(find.byType(ListView).first);
      expect(wallpaper, list, reason: 'it fills the transcript area');
      final stack = find.ancestor(
        of: find.byType(ChatWallpaper),
        matching: find.byType(Stack),
      );
      final children = tester.widget<Stack>(stack.first).children;
      expect(
        children.indexWhere((w) => w is Positioned && w.child is ChatWallpaper),
        0,
        reason: 'first child of the stack = painted below the messages',
      );
    });

    testWidgets('has none once the switch in Settings is off', (tester) async {
      SharedPreferences.setMockInitialValues({
        'verbose_mode': false,
        kChatWallpaperPref: false,
      });
      await openChat(tester);

      expect(find.byType(ChatWallpaper), findsNothing);
    });
  });
}

/// A server with an empty chat: `GET .../messages` answers, everything else is a 404.
class _EmptyServer extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final isMessages =
        request.method == 'GET' && request.url.path.endsWith('/messages');
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(jsonEncode(isMessages ? {'data': []} : {'error': 'x'})),
      ),
      isMessages ? 200 : 404,
      headers: {'content-type': 'application/json'},
    );
  }
}
