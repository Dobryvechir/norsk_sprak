import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/l10n/l10n.dart';
import 'package:norsk_audio_groups/l10n/translations/en.dart';

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
}
