import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/relative_time.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  final now = DateTime(2026, 10, 16, 12, 0);
  double ago(Duration d) => now.subtract(d).millisecondsSinceEpoch / 1000.0;

  group('without localizations (the original short form)', () {
    test('now, minutes, hours, days', () {
      expect(formatRelativeTime(now, ago(const Duration(seconds: 20))), 'now');
      expect(formatRelativeTime(now, ago(const Duration(minutes: 7))), '7m');
      expect(formatRelativeTime(now, ago(const Duration(hours: 3))), '3h');
      expect(formatRelativeTime(now, ago(const Duration(days: 2))), '2d');
    });

    test('a week or more is a numeric date', () {
      final lastActive = ago(const Duration(days: 9));
      final date = now.subtract(const Duration(days: 9));
      expect(formatRelativeTime(now, lastActive), '${date.day}/${date.month}');
    });
  });

  group('with localizations', () {
    test('Russian says "мин", "ч", "д" and "сейчас"', () async {
      final ru = await AppLocalizations.delegate.load(const Locale('ru'));
      expect(
        formatRelativeTime(now, ago(const Duration(seconds: 20)), l10n: ru),
        'сейчас',
      );
      expect(
        formatRelativeTime(now, ago(const Duration(minutes: 7)), l10n: ru),
        '7 мин',
      );
      expect(
        formatRelativeTime(now, ago(const Duration(hours: 3)), l10n: ru),
        '3 ч',
      );
      expect(
        formatRelativeTime(now, ago(const Duration(days: 2)), l10n: ru),
        '2 д',
      );
    });

    test('English keeps the compact form', () async {
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      expect(
        formatRelativeTime(now, ago(const Duration(minutes: 7)), l10n: en),
        '7m',
      );
    });

    test('an old date never throws, even without date symbols', () async {
      final ru = await AppLocalizations.delegate.load(const Locale('ru'));
      final text = formatRelativeTime(
        now,
        ago(const Duration(days: 30)),
        l10n: ru,
      );
      expect(text, isNotEmpty);
    });
  });
}
