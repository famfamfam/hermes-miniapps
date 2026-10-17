import 'package:flutter/cupertino.dart' show CupertinoLocalizations, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart';

/// Supplies the (English) Material/Cupertino strings for ANY language: the default delegates only
/// support `en`, which would otherwise make every Material widget fail under another test locale.
class AnyLanguageMaterial extends LocalizationsDelegate<MaterialLocalizations> {
  const AnyLanguageMaterial();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<MaterialLocalizations> load(Locale locale) => DefaultMaterialLocalizations.load(const Locale('en'));
  @override
  bool shouldReload(covariant LocalizationsDelegate<MaterialLocalizations> old) => false;
}

class AnyLanguageCupertino extends LocalizationsDelegate<CupertinoLocalizations> {
  const AnyLanguageCupertino();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<CupertinoLocalizations> load(Locale locale) => DefaultCupertinoLocalizations.load(const Locale('en'));
  @override
  bool shouldReload(covariant LocalizationsDelegate<CupertinoLocalizations> old) => false;
}

/// A MaterialApp whose resolved locale is [locale]. The existing assertions are Russian wording, so
/// Russian is the default; pass `Locale('en')` (or an unregistered one) to see the fallback language.
MaterialApp localizedApp({Locale locale = const Locale('ru'), Widget? home}) => MaterialApp(
  locale: locale,
  supportedLocales: [const Locale('en'), locale],
  localizationsDelegates: const [AnyLanguageMaterial(), AnyLanguageCupertino()],
  home: home,
);
