import 'package:flutter/material.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart' show SurfacesStrings, SurfacesText;

/// Visual weight of a status. Colours always come from the ambient [ColorScheme]; nothing here
/// owns a palette, so a themed host (dark brown/gold, light, high contrast) stays coherent.
enum AppsTone { neutral, ok, warn, error }

(Color background, Color foreground) toneColors(ColorScheme scheme, AppsTone tone) => switch (tone) {
  AppsTone.ok => (scheme.secondaryContainer, scheme.onSecondaryContainer),
  AppsTone.warn => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
  AppsTone.error => (scheme.errorContainer, scheme.onErrorContainer),
  AppsTone.neutral => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
};

/// The ONE connection status of the Apps screen: an icon plus a short text, nothing else.
class AppsStatusChip extends StatelessWidget {
  const AppsStatusChip({super.key, required this.icon, required this.label, this.tone = AppsTone.neutral});

  final IconData icon;
  final String label;
  final AppsTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (background, foreground) = toneColors(theme.colorScheme, tone);
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: foreground)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Deterministic, theme-derived avatar: the first letter of the title on a colour that depends
/// only on the app id (the theme's primary hue rotated by a stable hash, lightness by brightness).
class AppAvatar extends StatelessWidget {
  const AppAvatar({super.key, required this.appId, required this.title});

  final String appId;
  final String title;

  /// First letter (a whole rune, so emoji survive) of [title], falling back to [appId], upper-cased.
  static String initial(String title, String appId) {
    for (final source in [title.trim(), appId.trim()]) {
      if (source.isNotEmpty) return String.fromCharCode(source.runes.first).toUpperCase();
    }
    return '?';
  }

  /// FNV-1a over UTF-16 code units: stable across runs, platforms and Dart versions.
  static int stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  /// Background and foreground for [appId] under [scheme].
  static (Color, Color) colors(ColorScheme scheme, String appId) {
    final base = HSLColor.fromColor(scheme.primary);
    final hue = (base.hue + (stableHash(appId) % 12) * 30) % 360;
    final dark = scheme.brightness == Brightness.dark;
    final saturation = base.saturation.clamp(0.35, 0.7);
    HSLColor tone(double lightness) => HSLColor.fromAHSL(1, hue, saturation, lightness);
    return (tone(dark ? 0.30 : 0.84).toColor(), tone(dark ? 0.88 : 0.22).toColor());
  }

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = colors(Theme.of(context).colorScheme, appId);
    // The title next to it already names the app; do not read the letter out loud.
    return ExcludeSemantics(
      child: CircleAvatar(
        backgroundColor: background,
        foregroundColor: foreground,
        child: Text(initial(title, appId), style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// A quiet tip under the list: a small icon and one short sentence. Not a card and not a button, so
/// it never competes with the apps or with the single Chat action in the header.
class AppsHint extends StatelessWidget {
  const AppsHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(Icons.lightbulb_outline, size: 18, color: color)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

/// A calm explanation card: icon + title, optional message, short numbered steps, actions, footnote.
class AppsInfoCard extends StatelessWidget {
  const AppsInfoCard({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.steps = const [],
    this.actions = const [],
    this.footnote,
    this.tone = AppsTone.neutral,
  });

  final IconData icon;
  final String title;
  final String? message;
  final List<String> steps;
  final List<Widget> actions;
  final String? footnote;
  final AppsTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (background, foreground) = toneColors(scheme, tone);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ExcludeSemantics(
                  child: CircleAvatar(backgroundColor: background, foregroundColor: foreground, child: Icon(icon)),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
              ],
            ),
            if (message != null) ...[const SizedBox(height: 12), Text(message!)],
            for (var i = 0; i < steps.length; i++) ...[
              SizedBox(height: i == 0 ? 12 : 8),
              Semantics(
                label: SurfacesStrings.of(context)(SurfacesText.stepLabel, {'number': i + 1, 'text': steps[i]}),
                excludeSemantics: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: scheme.surfaceContainerHighest,
                      foregroundColor: scheme.onSurfaceVariant,
                      child: Text('${i + 1}', style: theme.textTheme.labelMedium),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(steps[i])),
                    ),
                  ],
                ),
              ),
            ],
            if (actions.isNotEmpty) ...[const SizedBox(height: 16), Wrap(spacing: 8, runSpacing: 8, children: actions)],
            if (footnote != null) ...[
              const SizedBox(height: 12),
              Text(footnote!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}
