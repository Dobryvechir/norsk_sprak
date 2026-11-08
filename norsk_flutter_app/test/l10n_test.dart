import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/l10n/l10n.dart';
import 'package:norsk_audio_groups/l10n/translations/en.dart';
import 'package:norsk_audio_groups/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Set<String> placeholders(String text) => {for (final m in RegExp(r'\{(\w+)\}').allMatches(text)) m.group(1)!};

void main() {
  test('every language is translated', () {
    expect(translations.keys.toSet(), languageNames.keys.toSet());
  });

  for (final entry in translations.entries) {
    test('${entry.key} has exactly the English keys and placeholders', () {
      expect(entry.value.keys.toSet(), stringsEn.keys.toSet());
      for (final key in stringsEn.keys) {
        expect(placeholders(entry.value[key]!), placeholders(stringsEn[key]!), reason: '${entry.key}.$key');
      }
    });
  }

  test('placeholders are filled in', () {
    expect(translate('nb', 'signedInAs', {'email': 'a@b.no'}), 'Logget inn som a@b.no');
    expect(translate('xx', 'menuChat'), 'Chat');
  });

  test('Flutter has its built-in widget texts for the locale of every language', () {
    for (final code in languageNames.keys) {
      for (final delegate in GlobalMaterialLocalizations.delegates) {
        expect(delegate.isSupported(localeFor(code)), isTrue, reason: '$code: ${delegate.runtimeType}');
      }
    }
  });

  test('Nynorsk has its own texts, and is kept when chosen', () async {
    expect(translate('nn', 'menuSettings'), 'Innstillingar');
    expect(localeFor('nn'), const Locale('nb'));
    expect(languageNames['nn'], 'Nynorsk');
    SharedPreferences.setMockInitialValues({'ui_language': 'nn', 'audio_language': 'nn', 'text_languages': ['nn', 'en']});
    final settings = AppSettings.instance;
    await settings.load();
    expect(settings.uiLanguage, 'nn');
    expect(settings.audioLanguage, 'nn');
    expect(settings.textLanguages, ['nn', 'en']);
  });

  testWidgets('built-in widgets work when the app language is Nynorsk', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: localeFor('nn'),
      supportedLocales: {for (final code in languageNames.keys) localeFor(code)}.toList(),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(appBar: AppBar(title: const Text('x')), body: const SizedBox()),
    ));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold));
    expect(MaterialLocalizations.of(context).closeButtonLabel, isNotEmpty);
    expect(Directionality.of(context), TextDirection.ltr);
    expect(tester.takeException(), isNull);
  });
}
