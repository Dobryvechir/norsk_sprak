import 'package:flutter/widgets.dart';
import '../services/settings.dart';
import 'translations/bg.dart';
import 'translations/cs.dart';
import 'translations/da.dart';
import 'translations/de.dart';
import 'translations/el.dart';
import 'translations/en.dart';
import 'translations/es.dart';
import 'translations/fr.dart';
import 'translations/he.dart';
import 'translations/it.dart';
import 'translations/nb.dart';
import 'translations/pl.dart';
import 'translations/pt.dart';
import 'translations/ru.dart';
import 'translations/sv.dart';
import 'translations/uk.dart';

const defaultLanguage = 'en';

/// Supported language codes, each with the language's own name.
const languageNames = {
  'en': 'English', 'nb': 'Norsk', 'uk': 'Українська', 'ru': 'Русский',
  'de': 'Deutsch', 'da': 'Dansk', 'sv': 'Svenska', 'cs': 'Čeština',
  'bg': 'Български', 'pl': 'Polski', 'pt': 'Português', 'es': 'Español',
  'fr': 'Français', 'el': 'Ελληνικά', 'he': 'עברית', 'it': 'Italiano',
};

const translations = <String, Map<String, String>>{
  'en': stringsEn, 'nb': stringsNb, 'uk': stringsUk, 'ru': stringsRu,
  'de': stringsDe, 'da': stringsDa, 'sv': stringsSv, 'cs': stringsCs,
  'bg': stringsBg, 'pl': stringsPl, 'pt': stringsPt, 'es': stringsEs,
  'fr': stringsFr, 'el': stringsEl, 'he': stringsHe, 'it': stringsIt,
};

/// [codes] in the order of [languageNames], skipping unknown ones.
List<String> orderedLanguages(Iterable<String> codes) {
  final set = codes.toSet();
  return [for (final code in languageNames.keys) if (set.contains(code)) code];
}

/// Flutter locale for a language code (our codes are the standard ISO 639-1 ones).
Locale localeFor(String code) => Locale(code);

/// Translates [key] into [language] (falling back to English), filling `{name}` placeholders from [args].
String translate(String language, String key, [Map<String, Object?> args = const {}]) {
  var text = translations[language]?[key] ?? stringsEn[key] ?? key;
  args.forEach((name, value) => text = text.replaceAll('{$name}', '$value'));
  return text;
}

/// Translates into the current UI language. For code outside widgets, such as error messages;
/// widgets use `context.tr` so they rebuild when the language changes.
String trNow(String key, [Map<String, Object?> args = const {}]) => translate(AppSettings.instance.uiLanguage, key, args);

/// Rebuilds the widgets that use `context.tr` whenever the settings change.
class L10nScope extends InheritedNotifier<AppSettings> {
  const L10nScope({super.key, required super.notifier, required super.child});
}

extension L10nContext on BuildContext {
  String tr(String key, [Map<String, Object?> args = const {}]) {
    dependOnInheritedWidgetOfExactType<L10nScope>();
    return translate(AppSettings.instance.uiLanguage, key, args);
  }

  /// Recording status from the server, translated when it's a known one.
  String trStatus(String status) => switch (status) {
    'pending' => tr('statusPending'), 'processing' => tr('statusProcessing'),
    'ready' || 'completed' => tr('statusReady'), 'failed' => tr('statusFailed'), _ => status,
  };

  /// Group role (viewer/uploader/admin), translated.
  String trRole(String role) => switch (role) {
    'viewer' => tr('roleViewer'), 'uploader' => tr('roleUploader'), 'admin' => tr('roleAdmin'), _ => role,
  };
}
