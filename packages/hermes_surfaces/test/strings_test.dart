import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';

/// The string layer is plain data: these tests keep every language complete and consistent, so
/// adding one is a single map entry that cannot silently miss a key or break a placeholder.
void main() {
  final languages = SurfacesStrings.catalog.keys.toList();
  final placeholder = SurfacesStrings.placeholder;

  Set<String> namesIn(String template) => {for (final m in placeholder.allMatches(template)) m.group(1)!};

  group('catalog', () {
    test('English is registered, Russian is the second complete language', () {
      expect(languages, containsAll(['en', 'ru']));
      expect(SurfacesStrings.fallbackLanguage, 'en');
      expect(SurfacesStrings.languages.first, 'en');
    });

    for (final language in languages) {
      test('$language has every key exactly once and no empty text', () {
        final table = SurfacesStrings.catalog[language]!;
        expect(table.length, SurfacesText.values.length, reason: 'a missing or extra key');
        for (final key in SurfacesText.values) {
          expect(table.containsKey(key), isTrue, reason: '$language lacks $key');
          expect(table[key]!.trim(), isNotEmpty, reason: '$language has an empty $key');
        }
      });
    }

    test('the same placeholders appear in every language, and filling them leaves none open', () {
      final english = SurfacesStrings.catalog['en']!;
      for (final language in languages) {
        final table = SurfacesStrings.catalog[language]!;
        for (final key in SurfacesText.values) {
          final names = namesIn(english[key]!);
          expect(namesIn(table[key]!), names, reason: '$language/$key placeholders differ from English');
          final args = {for (final name in names) name: 'SAMPLE_$name'};
          final filled = SurfacesStrings.forLanguage(language)(key, args);
          expect(placeholder.hasMatch(filled), isFalse, reason: '$language/$key left a placeholder: $filled');
          expect(filled.contains('{') || filled.contains('}'), isFalse, reason: '$language/$key has a stray brace');
          for (final name in names) {
            expect(filled, contains('SAMPLE_$name'), reason: '$language/$key never uses {$name}');
          }
        }
      }
    });

    test('Russian is a real translation: no key is left as the English source', () {
      final english = SurfacesStrings.catalog['en']!;
      final russian = SurfacesStrings.catalog['ru']!;
      final copied = [
        for (final key in SurfacesText.values)
          if (english[key] == russian[key]) key,
      ];
      expect(copied, isEmpty);
    });

    test('the create-app hint and the chat-address button are complete, plain sentences in both languages', () {
      const texts = {
        'en': (
          'To create an app, ask Hermes in chat, for example: “Make a monthly expenses screen”.',
          'Use the chat server address',
        ),
        'ru': (
          'Чтобы создать приложение, попросите Hermes в чате: «Сделай экран учёта трат за месяц».',
          'Подставить адрес с сервера чата',
        ),
      };
      for (final entry in texts.entries) {
        final strings = SurfacesStrings.forLanguage(entry.key);
        expect(strings(SurfacesText.createAppHint), entry.value.$1, reason: entry.key);
        expect(strings(SurfacesText.useChatAddress), entry.value.$2, reason: entry.key);
      }
    });

    test('values never carry a credential-looking or address-looking literal', () {
      for (final table in SurfacesStrings.catalog.values) {
        for (final text in table.values) {
          expect(text, isNot(matches(RegExp(r'https?://|Bearer\s|[A-Za-z0-9+/]{32,}'))));
        }
      }
    });
  });

  group('language resolution', () {
    test('unknown, missing and English locales use English', () {
      for (final code in <String?>[null, '', 'en', 'EN', 'en_US', 'de', 'ja', 'pt_BR', 'zz']) {
        expect(SurfacesStrings.forLanguage(code).languageCode, 'en', reason: '$code');
      }
    });

    test('Russian is picked for ru in any common spelling', () {
      for (final code in ['ru', 'RU', 'ru_RU', 'ru-RU']) {
        final strings = SurfacesStrings.forLanguage(code);
        expect(strings.languageCode, 'ru', reason: code);
        expect(strings(SurfacesText.openChat), 'Открыть чат');
      }
      expect(SurfacesStrings.forLanguage('en')(SurfacesText.openChat), 'Open chat');
    });

    test('placeholders are filled from the arguments, unknown ones are left visible for tests to catch', () {
      expect(
        SurfacesStrings.forLanguage('ru')(SurfacesText.chipOfflineSince, {'time': '12:19'}),
        'Нет связи · данные от 12:19',
      );
      expect(
        SurfacesStrings.forLanguage('en')(SurfacesText.chipOfflineSince, {'time': '12:19'}),
        'Offline · data from 12:19',
      );
      expect(SurfacesStrings.forLanguage('en')(SurfacesText.appUpdate, {'other': 1}), contains('{revision}'));
      expect(SurfacesStrings.forLanguage('en').describe(null, 'server said so'), 'server said so');
      expect(
        SurfacesStrings.forLanguage('en').describe(SurfacesText.hostUnauthorized, 'ignored'),
        'No access: check the token',
      );
    });

    testWidgets('of(context) follows the ambient Localizations, with no delegate of ours installed', (tester) async {
      String? seen;
      Future<void> pumpWith(Locale? locale) async {
        final probe = Builder(
          builder: (context) {
            seen = SurfacesStrings.of(context).languageCode;
            return const SizedBox();
          },
        );
        await tester.pumpWidget(
          locale == null
              ? probe
              : Localizations(locale: locale, delegates: const [DefaultWidgetsLocalizations.delegate], child: probe),
        );
      }

      await pumpWith(null);
      expect(seen, 'en', reason: 'no Localizations at all');
      await pumpWith(const Locale('ru'));
      expect(seen, 'ru');
      await pumpWith(const Locale('ru', 'RU'));
      expect(seen, 'ru');
      await pumpWith(const Locale('en'));
      expect(seen, 'en');
      await pumpWith(const Locale('de'));
      expect(seen, 'en', reason: 'unregistered language falls back to English');
    });
  });

  test('counts per language are reported by the catalog', () {
    for (final language in languages) {
      expect(SurfacesStrings.catalog[language]!.length, SurfacesText.values.length);
    }
  });
}
