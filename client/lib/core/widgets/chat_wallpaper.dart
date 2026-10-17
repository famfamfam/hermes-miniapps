import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Hand-drawn doodle wallpaper behind the chat transcript, in the spirit of a
/// messenger's pattern: small pencil drawings (a paper plane, a cup, a wing,
/// a receipt, ...) on a triangular lattice, drawn faintly so text stays easy
/// to read.
///
/// Everything is procedural and deterministic: one tile is drawn once (pencil
/// strokes with a wobbling line, a pressure that swells and fades, tapered
/// ends, a closed outline that overshoots its start and a second, thinner
/// sketch pass), cached as a picture and repeated. The tile wraps on both
/// axes, so there are no seams. The layer does not scroll with the messages
/// and sits in its own repaint boundary, so scrolling never repaints it.
class ChatWallpaper extends StatelessWidget {
  const ChatWallpaper({super.key, this.opacity});

  /// Strength of the whole pattern, 0..1. Defaults to a value tuned per
  /// brightness.
  final double? opacity;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _WallpaperPainter(
            dark: dark,
            opacity:
                opacity ??
                (dark ? kDarkWallpaperOpacity : kLightWallpaperOpacity),
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// SharedPreferences key of the Settings switch; the wallpaper is on unless it
/// is switched off.
const String kChatWallpaperPref = 'chat_wallpaper';

const double kDarkWallpaperOpacity = 0.12;
const double kLightWallpaperOpacity = 0.11;

/// Size of one repeating tile, in logical pixels.
const double kWallpaperTileWidth = 368;
const double kWallpaperTileHeight = 320;

// Pencil colours by role: warm paper-white graphite on dark, sepia on light.
const Color _darkInk = Color(0xFFF6E6CC);
const Color _lightInk = Color(0xFF5A3E2B);

class _WallpaperPainter extends CustomPainter {
  const _WallpaperPainter({required this.dark, required this.opacity});

  final bool dark;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final tile = chatWallpaperTile(dark: dark);
    canvas.save();
    canvas.clipRect(bounds);
    // One group alpha for the whole pattern: overlapping strokes of the same
    // drawing must not show up as darker beads.
    canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    for (var y = 0.0; y < size.height; y += kWallpaperTileHeight) {
      for (var x = 0.0; x < size.width; x += kWallpaperTileWidth) {
        canvas.save();
        canvas.translate(x, y);
        canvas.drawPicture(tile);
        canvas.restore();
      }
    }
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WallpaperPainter old) =>
      old.dark != dark || old.opacity != opacity;
}

final Map<bool, ui.Picture> _tileCache = {};

/// The cached tile for the given brightness (strokes are opaque; the group
/// alpha is applied when the tiles are painted).
@visibleForTesting
ui.Picture chatWallpaperTile({required bool dark}) => _tileCache.putIfAbsent(
  dark,
  () => _recordTile(dark ? _darkInk : _lightInk),
);

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

const double _colStep = 92;
const double _rowStep = 80;
const int _cols = 4;
const int _rows = 4;
const double _doodleSize = 54;

/// Which drawing sits where, row by row. Hand-ordered so similar shapes are
/// not neighbours.
const List<_Kind> _layout = [
  _Kind.plane,
  _Kind.heart,
  _Kind.cloud,
  _Kind.star,
  _Kind.bubble,
  _Kind.cup,
  _Kind.moon,
  _Kind.key,
  _Kind.leaf,
  _Kind.wing,
  _Kind.envelope,
  _Kind.bulb,
  _Kind.gear,
  _Kind.smiley,
  _Kind.receipt,
  _Kind.note,
];

enum _Kind {
  plane,
  heart,
  cloud,
  star,
  bubble,
  cup,
  moon,
  key,
  leaf,
  wing,
  envelope,
  bulb,
  gear,
  smiley,
  receipt,
  note,
}

ui.Picture _recordTile(Color ink) {
  final recorder = ui.PictureRecorder();
  const tile = Rect.fromLTWH(0, 0, kWallpaperTileWidth, kWallpaperTileHeight);
  final canvas = Canvas(recorder, tile);
  canvas.clipRect(tile);

  final shifts = <int>[-1, 0, 1];
  void drawWrapped(Rect box, void Function(Canvas c) draw) {
    for (final dy in shifts) {
      for (final dx in shifts) {
        final moved = box.shift(
          Offset(dx * kWallpaperTileWidth, dy * kWallpaperTileHeight),
        );
        if (!moved.overlaps(tile)) continue;
        canvas.save();
        canvas.translate(dx * kWallpaperTileWidth, dy * kWallpaperTileHeight);
        draw(canvas);
        canvas.restore();
      }
    }
  }

  var index = 0;
  for (var r = 0; r < _rows; r++) {
    for (var c = 0; c < _cols; c++, index++) {
      final seed = 1000 + index * 7;
      final x0 = _colStep / 2 + c * _colStep + (r.isOdd ? _colStep / 2 : 0);
      final y0 = _rowStep / 2 + r * _rowStep;
      final center = Offset(
        x0 + (_rnd(seed, 1) - .5) * 16,
        y0 + (_rnd(seed, 2) - .5) * 16,
      );
      final angle = (_rnd(seed, 3) - .5) * 2 * (22 * math.pi / 180);
      final size = _doodleSize + (_rnd(seed, 4) - .5) * 10;
      final strokes = _normalised(_drawing(_layout[index]), size / 2, angle);
      final box = Rect.fromCenter(
        center: center,
        width: size * 1.5,
        height: size * 1.5,
      );
      drawWrapped(box, (pen) {
        var n = 0;
        for (final line in strokes) {
          _penStroke(
            pen,
            line,
            center: center,
            ink: ink,
            seed: seed * 31 + n++,
          );
        }
      });

      // A small filler in the gaps of the lattice.
      for (final second in const [false, true]) {
        if (second && (r + c).isOdd) continue;
        final fx = x0 + (second ? _colStep : _colStep / 2);
        final fy = y0 + (second ? _rowStep * 2 / 3 : _rowStep / 3);
        final fseed = seed * 17 + (second ? 5 : 3);
        final spot = Offset(
          fx + (_rnd(fseed, 1) - .5) * 8,
          fy + (_rnd(fseed, 2) - .5) * 8,
        );
        final fillerBox = Rect.fromCenter(center: spot, width: 24, height: 24);
        drawWrapped(fillerBox, (pen) => _filler(pen, spot, fseed, ink));
      }
    }
  }
  return recorder.endRecording();
}

void _filler(Canvas canvas, Offset at, int seed, Color ink) {
  final fill = Paint()..color = ink;
  switch (_h(seed, 9) % 4) {
    case 0: // three dots
      for (var i = 0; i < 3; i++) {
        canvas.drawCircle(
          at +
              Offset(
                (i - 1) * 6.0,
                (i == 1 ? -2.5 : 1.5) + (_rnd(seed, 20 + i) - .5),
              ),
          1.3 + _rnd(seed, 30 + i) * .5,
          fill,
        );
      }
    case 1: // a small cross
      final a = (_rnd(seed, 4) - .5) * .6;
      for (var k = 0; k < 2; k++) {
        final t = a + k * math.pi / 2;
        final d = Offset(math.cos(t), math.sin(t)) * 4.5;
        _penStroke(
          canvas,
          _Line([-d, d]),
          center: at,
          ink: ink,
          seed: seed + k,
          width: 1.3,
        );
      }
    case 2: // a tiny four-point spark
      final pts = <Offset>[
        for (var i = 0; i < 8; i++)
          Offset.fromDirection(
            -math.pi / 2 + i * math.pi / 4,
            i.isEven ? 6.5 : 1.6,
          ),
      ];
      _penStroke(
        canvas,
        _Line(pts, closed: true),
        center: at,
        ink: ink,
        seed: seed,
        width: 1.3,
      );
    default: // a ring
      _penStroke(
        canvas,
        _Line(_arc(0, 0, 3.6, 3.6, 0, 360), closed: true),
        center: at,
        ink: ink,
        seed: seed,
        width: 1.3,
      );
  }
}

// ---------------------------------------------------------------------------
// The pencil
// ---------------------------------------------------------------------------

class _Line {
  const _Line(this.points, {this.closed = false});
  final List<Offset> points;
  final bool closed;
}

/// Scales a drawing from its own units to [radius] pixels (largest side =
/// 2 * radius), centred on its bounding box and turned by [angle].
List<_Line> _normalised(List<_Line> lines, double radius, double angle) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final line in lines) {
    for (final p in line.points) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
  }
  final mid = Offset((minX + maxX) / 2, (minY + maxY) / 2);
  final scale = radius / (math.max(maxX - minX, maxY - minY) / 2);
  final cosA = math.cos(angle), sinA = math.sin(angle);
  Offset move(Offset p) {
    final q = (p - mid) * scale;
    return Offset(q.dx * cosA - q.dy * sinA, q.dx * sinA + q.dy * cosA);
  }

  return [
    for (final line in lines)
      _Line([for (final p in line.points) move(p)], closed: line.closed),
  ];
}

/// Draws one line as a pencil would: a main pass and a thinner, fainter
/// sketch pass that wanders a little differently.
void _penStroke(
  Canvas canvas,
  _Line line, {
  required Offset center,
  required Color ink,
  required int seed,
  double width = 1.7,
}) {
  _ribbon(canvas, line, center, ink, seed, width, wobble: 1.0);
  _ribbon(
    canvas,
    line,
    center,
    ink.withValues(alpha: .5),
    seed ^ 0x5bd1e995,
    width * .42,
    wobble: 1.5,
  );
}

void _ribbon(
  Canvas canvas,
  _Line line,
  Offset center,
  Color color,
  int seed,
  double width, {
  required double wobble,
}) {
  var pts = _resample(
    line.closed ? [...line.points, line.points.first] : line.points,
    2.4,
  );
  if (pts.length < 2) return;
  if (line.closed) {
    // The pencil does not stop where it started: run ~5% past the start.
    final extra = math.min(
      math.max(2, (pts.length * .05).ceil()),
      pts.length - 1,
    );
    pts = [...pts, ...pts.sublist(1, extra + 1)];
  }

  final s = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    s.add(s.last + (pts[i] - pts[i - 1]).distance);
  }
  final total = s.last;
  final ramp = math.min(total * .14, 9.0);

  final left = <Offset>[];
  final right = <Offset>[];
  for (var i = 0; i < pts.length; i++) {
    final a = pts[math.max(i - 1, 0)];
    final b = pts[math.min(i + 1, pts.length - 1)];
    final d = b - a;
    final len = d.distance;
    if (len == 0) continue;
    final normal = Offset(-d.dy / len, d.dx / len);

    final wander =
        _vnoise(seed, s[i] / 15) * .8 + _vnoise(seed + 1, s[i] / 5.5) * .3;
    final pressure = 1 + .2 * _vnoise(seed + 77, s[i] / 17);
    final head = ramp == 0 ? 1.0 : math.min(1.0, s[i] / ramp);
    final tail = ramp == 0 ? 1.0 : math.min(1.0, (total - s[i]) / ramp);
    final taper = .25 + .75 * math.sin(math.min(head, tail) * math.pi / 2);

    final p = center + pts[i] + normal * (wander * wobble);
    final half = width * pressure * taper / 2;
    left.add(p + normal * half);
    right.add(p - normal * half);
  }
  if (left.length < 2) return;

  final path = Path()..moveTo(left.first.dx, left.first.dy);
  for (final p in left.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  for (final p in right.reversed) {
    path.lineTo(p.dx, p.dy);
  }
  path.close();
  canvas.drawPath(path, Paint()..color = color);
}

List<Offset> _resample(List<Offset> pts, double step) {
  if (pts.length < 2) return pts;
  final out = <Offset>[pts.first];
  var carried = 0.0;
  for (var i = 1; i < pts.length; i++) {
    var from = pts[i - 1];
    final to = pts[i];
    var seg = (to - from).distance;
    if (seg == 0) continue;
    while (carried + seg >= step) {
      final t = (step - carried) / seg;
      from = Offset.lerp(from, to, t)!;
      out.add(from);
      seg = (to - from).distance;
      carried = 0;
    }
    carried += seg;
  }
  if ((out.last - pts.last).distance > .01) out.add(pts.last);
  return out;
}

// Deterministic noise: no dart:math Random (its sequence is not promised to be
// stable between SDK versions), so the wallpaper is the same everywhere.
int _h(int a, int b) {
  var x = (a * 0x27D4EB2D + b * 0x165667B1 + 0x1B873593) & 0xFFFFFFFF;
  x = ((x ^ (x >> 15)) * 0x85EBCA6B) & 0xFFFFFFFF;
  x = ((x ^ (x >> 13)) * 0xC2B2AE35) & 0xFFFFFFFF;
  return (x ^ (x >> 16)) & 0xFFFFFFFF;
}

double _rnd(int a, int b) => _h(a, b) / 0xFFFFFFFF;

double _vnoise(int seed, double x) {
  final i = x.floor();
  final f = x - i;
  final u = f * f * (3 - 2 * f);
  final a = _rnd(seed, i) * 2 - 1;
  final b = _rnd(seed, i + 1) * 2 - 1;
  return a + (b - a) * u;
}

// ---------------------------------------------------------------------------
// The doodles, in their own units (y points down). Each is a few lines.
// ---------------------------------------------------------------------------

List<Offset> _arc(
  double cx,
  double cy,
  double rx,
  double ry,
  double fromDeg,
  double toDeg,
) {
  final n = math.max(8, ((toDeg - fromDeg).abs() / 7).ceil());
  final out = <Offset>[];
  for (var i = 0; i <= n; i++) {
    final a = (fromDeg + (toDeg - fromDeg) * i / n) * math.pi / 180;
    out.add(Offset(cx + rx * math.cos(a), cy + ry * math.sin(a)));
  }
  return out;
}

List<Offset> _bezier(Offset p0, Offset c1, Offset c2, Offset p3, [int n = 22]) {
  return [
    for (var i = 0; i <= n; i++)
      () {
        final t = i / n, u = 1 - t;
        return p0 * (u * u * u) +
            c1 * (3 * u * u * t) +
            c2 * (3 * u * t * t) +
            p3 * (t * t * t);
      }(),
  ];
}

List<Offset> _quad(Offset p0, Offset c, Offset p2, [int n = 12]) {
  return [
    for (var i = 0; i <= n; i++)
      () {
        final t = i / n, u = 1 - t;
        return p0 * (u * u) + c * (2 * u * t) + p2 * (t * t);
      }(),
  ];
}

Offset _o(double x, double y) => Offset(x, y);

List<_Line> _drawing(_Kind kind) => switch (kind) {
  _Kind.plane => [
    _Line([_o(-1, 0), _o(1, -1), _o(.3, 1), _o(-.15, .3)], closed: true),
    _Line([_o(-.15, .3), _o(1, -1)]),
    _Line([_o(-.15, .3), _o(.05, .78)]),
  ],
  _Kind.heart => [
    _Line([
      for (var i = 0; i < 48; i++)
        () {
          final t = i / 48 * 2 * math.pi;
          return _o(
            16 * math.pow(math.sin(t), 3).toDouble() / 17,
            -(13 * math.cos(t) -
                    5 * math.cos(2 * t) -
                    2 * math.cos(3 * t) -
                    math.cos(4 * t)) /
                17,
          );
        }(),
    ], closed: true),
  ],
  _Kind.cloud => [
    _Line([
      _o(-.3, .4),
      _o(.6, .4),
      ..._arc(.6, .1, .3, .3, 90, -90),
      ..._arc(.15, -.2, .45, .45, 0, -180),
      ..._arc(-.3, .1, .3, .3, -90, -270),
    ], closed: true),
  ],
  _Kind.star => [
    _Line([
      for (var i = 0; i < 10; i++)
        Offset.fromDirection(
          -math.pi / 2 + i * math.pi / 5,
          i.isEven ? 1 : .42,
        ),
    ], closed: true),
  ],
  _Kind.bubble => [
    _Line([..._arc(0, -.1, 1, .7, 125, 465), _o(-.85, .98)], closed: true),
    _Line([_o(-.5, -.25), _o(.5, -.25)]),
    _Line([_o(-.5, .08), _o(.2, .08)]),
  ],
  _Kind.cup => [
    _Line([
      _o(-.75, -.2),
      _o(.55, -.2),
      _o(.47, .45),
      ..._quad(_o(.47, .45), _o(-.1, .85), _o(-.6, .45)),
    ], closed: true),
    _Line(_arc(.55, .12, .32, .28, -90, 90)),
    for (final x0 in const [-.35, .05])
      _Line([
        for (var i = 0; i <= 14; i++)
          _o(x0 + .09 * math.sin(i / 14 * 2 * math.pi), -.4 - i / 14 * .55),
      ]),
  ],
  _Kind.moon => [
    _Line([
      ..._arc(0, 0, 1, 1, 52.4, 307.6),
      ..._arc(.5, 0, .8, .8, 277.9, 82.1),
    ], closed: true),
  ],
  _Kind.key => [
    _Line(_arc(-.55, 0, .38, .38, 0, 360), closed: true),
    _Line(_arc(-.55, 0, .13, .13, 0, 360), closed: true),
    _Line([_o(-.17, 0), _o(.95, 0), _o(.95, .34)]),
    _Line([_o(.68, 0), _o(.68, .26)]),
  ],
  _Kind.leaf => [
    _Line([
      ..._bezier(_o(-.9, .9), _o(-1, -.3), _o(.1, -.9), _o(.9, -.9)),
      ..._bezier(_o(.9, -.9), _o(1, .3), _o(-.1, .9), _o(-.9, .9)),
    ], closed: true),
    _Line([_o(-.9, .9), _o(.45, -.45)]),
    for (final t in const [.3, .62])
      for (final side in const [1.0, -1.0])
        _Line([
          _o(-.9 + 1.35 * t, .9 - 1.35 * t),
          _o(
            -.9 + 1.35 * t + .3 * (side * .8 * .707 + .6 * .707),
            .9 - 1.35 * t + .3 * (side * .8 * .707 - .6 * .707),
          ),
        ]),
  ],
  _Kind.wing => [
    _Line([
      ..._bezier(_o(-.95, .55), _o(-.9, -.35), _o(-.1, -.85), _o(.95, -.7)),
      ..._quad(_o(.95, -.7), _o(.9, -.2), _o(.5, -.15)),
      ..._quad(_o(.5, -.15), _o(.5, .2), _o(.05, .2)),
      ..._quad(_o(.05, .2), _o(0, .5), _o(-.4, .45)),
      ..._quad(_o(-.4, .45), _o(-.4, .75), _o(-.95, .55)),
    ], closed: true),
    _Line([_o(.5, -.15), _o(-.05, -.35)]),
    _Line([_o(.05, .2), _o(-.45, 0)]),
  ],
  _Kind.envelope => [
    _Line([_o(-1, -.65), _o(1, -.65), _o(1, .65), _o(-1, .65)], closed: true),
    _Line([_o(-1, -.65), _o(0, .1), _o(1, -.65)]),
    _Line([_o(-1, .65), _o(-.35, 0)]),
    _Line([_o(1, .65), _o(.35, 0)]),
  ],
  _Kind.bulb => [
    _Line([
      _o(-.25, .62),
      ..._arc(0, -.25, .62, .62, 125, 415),
      _o(.25, .62),
    ], closed: true),
    _Line([_o(-.2, .8), _o(.2, .8)]),
    _Line([_o(-.12, .97), _o(.12, .97)]),
    _Line([
      _o(-.18, .6),
      _o(-.18, .15),
      _o(0, -.05),
      _o(.18, .15),
      _o(.18, .6),
    ]),
  ],
  _Kind.gear => [
    _Line([
      for (var k = 0; k < 8; k++) ...[
        Offset.fromDirection((k * 45 - 11) * math.pi / 180, .78),
        Offset.fromDirection((k * 45 - 7) * math.pi / 180, 1),
        Offset.fromDirection((k * 45 + 7) * math.pi / 180, 1),
        Offset.fromDirection((k * 45 + 11) * math.pi / 180, .78),
      ],
    ], closed: true),
    _Line(_arc(0, 0, .34, .34, 0, 360), closed: true),
  ],
  _Kind.smiley => [
    _Line(_arc(0, 0, 1, 1, 0, 360), closed: true),
    _Line([_o(-.35, -.42), _o(-.35, -.1)]),
    _Line([_o(.35, -.42), _o(.35, -.1)]),
    _Line(_arc(0, .05, .55, .5, 25, 155)),
  ],
  _Kind.receipt => [
    _Line([
      _o(-.6, -1),
      _o(.6, -1),
      _o(.6, .85),
      _o(.4, .7),
      _o(.2, .85),
      _o(0, .7),
      _o(-.2, .85),
      _o(-.4, .7),
      _o(-.6, .85),
    ], closed: true),
    _Line([_o(-.35, -.65), _o(.35, -.65)]),
    _Line([_o(-.35, -.3), _o(.35, -.3)]),
    _Line([_o(-.35, .05), _o(.1, .05)]),
    _Line([_o(-.35, .4), _o(.35, .4)]),
  ],
  _Kind.note => [
    _Line(_arc(-.35, .6, .34, .25, 0, 360), closed: true),
    _Line([_o(0, .55), _o(0, -.95)]),
    _Line(_bezier(_o(0, -.95), _o(.1, -.5), _o(.65, -.5), _o(.6, -.1))),
  ],
};
