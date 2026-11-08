@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/models/entities.dart';
import 'package:norsk_audio_groups/screens/chapters_screen.dart';
import 'package:norsk_audio_groups/screens/word_translation.dart';
import 'package:norsk_audio_groups/services/api.dart';
import 'package:norsk_audio_groups/services/dictionaries.dart';
import 'package:norsk_audio_groups/services/settings.dart';
import 'package:norsk_audio_groups/services/word_dictionary.dart';
import 'package:path/path.dart' as p;

/// Shaped like data/dictionaries/dict_nb.json.
const sample = <String, dynamic>{
  'a-lag': {
    'or': 'A-lag', 'tr': {'en': 'A team', 'uk': 'команда А', 'de': 'A-Mannschaft'}, 'gender': 'nn n1',
    'declination': {'Sing-Ind': 'A-lag,a-lag', 'Plur-Def': 'A-laga,A-lagene', '': 'a,à', 'Future': 'x'},
    'description': [{'orig': 'førstelag', 'tr': {'en': 'first team', 'pl': 'Pierwsza drużyna'}}],
    'deepDescription': [{'orig': 'klubbens A-lag', 'tr': {'en': 'The club\'s A team'}}],
    'expression': [{'orig': 'fra A til B', 'tran': {'orig': 'fra A til B', 'tr': {'en': 'from A to B'}},
      'description': [{'orig': 'fra et sted til et annet', 'tr': {'en': 'from one place to another'}}]}],
  },
  'abba': {'or': 'Abba', 'tr': {'en': 'Abba-en', 'uk': 'Абба-uk'}},
  'abde’els': {'or': 'Abde’els', 'tr': {'en': 'Abdeels'}},
  'tom': {'or': 'tom', 'tr': {'uk': 'порожній'}},
  'broken': 'not an entry',
};

/// The senses of "a", as in data/dictionaries/dict_nb.json.
const withSenses = <String, dynamic>{
  'a': {
    'or': 'a', 'tr': {'en': 'a'}, 'description': [{'orig': 'bokstav', 'tr': {'en': 'letter'}}],
    'senses': [
      {'id': 'letter', 'pos': 'noun', 'gloss': 'bokstavtegn og språklyd', 'from': [0], 'tr': {'en': ['the letter a'], 'uk': ['літера а'], 'pl': ['litera a']}},
      {'id': 'note', 'pos': 'noun', 'domain': 'music', 'gloss': 'sjette tone i C-durskalaen', 'from': [1],
        'tr': {'en': ['A (note)'], 'uk': ['ля'], 'pl': ['a (dźwięk)', 'la']}, 'notes': {'uk': 'Ukrainian uses the name ля, not the letter.'}},
      {'id': 'grade', 'pos': 'noun', 'gloss': 'beste karakter', 'from': [4], 'tr': {'en': ['A (top grade)']}},
    ],
    'uncertain': false, 'reviewed': false,
  },
};

class _FakeSaved extends SavedDictionaries {
  _FakeSaved(this.dictionaries);
  final Map<String, WordDictionary> dictionaries;
  Object? loadError;
  int loads = 0;
  @override Future<bool> has(String lang) async => dictionaries.containsKey(lang);
  @override Future<WordDictionary> load(String lang) async {
    loads++;
    if (loadError != null) throw loadError!;
    return dictionaries[lang]!;
  }
}

const chapter = Recording('c', '', 'K', {}, {
  'nb': ['Abba, ukjent A-LAG!', 'tom Abba.'], 'en': ['Line one.', 'Line two.'], 'uk': ['Рядок один.', 'Рядок два.'],
}, 's');

/// The spans of the word translation line: the one rich text with a tappable word in it.
List<TextSpan> wordSpans(WidgetTester tester) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    final spans = <TextSpan>[];
    rich.text.visitChildren((s) { if (s is TextSpan && s.text != null) spans.add(s); return true; });
    if (spans.any((s) => s.recognizer != null)) return spans;
  }
  return const [];
}

void main() {
  group('sentences and lookups', () {
    final dictionary = WordDictionary(sample);
    test('a word is found in any case; hyphens and either apostrophe belong to it', () {
      expect(dictionary.lookup('ABBA')?.original, 'Abba');
      expect(dictionary.lookup('A-Lag')?.original, 'A-lag');
      expect(dictionary.lookup("Abde'els")?.original, 'Abde’els');
      expect(dictionary.lookup('Abde’els')?.original, 'Abde’els');
      expect(dictionary.lookup('ukjent'), isNull);
      expect(dictionary.lookup('broken'), isNull);
    });
    test('a sentence is cut into known words and unchanged text, losing nothing', () {
      const sentence = '«Abba», sa Ukjent: A-LAG\'et a-lag; abde’els!';
      final parts = dictionary.analyze(sentence);
      expect(parts.map((x) => x.text).join(), sentence);
      expect(parts.where((x) => x.entry != null).map((x) => x.text), ['Abba', 'a-lag', 'abde’els']);
      expect(dictionary.analyze('').isEmpty, isTrue);
      expect(dictionary.analyze('—').single.entry, isNull);
    });
    test('senses are read; a wrong shape is tolerated, and an entry without them has none', () {
      final senses = WordDictionary(withSenses).lookup('a')!.senses;
      expect(senses.map((s) => s.id), ['letter', 'note', 'grade']);
      final note = senses[1];
      expect([note.pos, note.domain, note.register, note.gloss], ['noun', 'music', '', 'sjette tone i C-durskalaen']);
      expect(note.from, [1]);
      expect(note.tr['pl'], ['a (dźwięk)', 'la']);
      expect(note.notes['uk'], 'Ukrainian uses the name ля, not the letter.');
      expect(dictionary.lookup('abba')!.senses, isEmpty);

      final odd = WordDictionary(const {'x': {'or': 'x', 'tr': <String, String>{}, 'senses': ['not a sense', {'tr': {'en': 'one string', 'uk': null}, 'from': ['y', 2]}]}}).lookup('x')!.senses;
      expect(odd.single.tr, {'en': ['one string']});
      expect(odd.single.from, [2]);
      expect(WordDictionary(const {'x': {'or': 'x', 'senses': 'none'}}).lookup('x')!.senses, isEmpty);
    });
    test('every part of an entry is read; missing parts are empty', () {
      final full = dictionary.lookup('a-lag')!;
      expect(full.gender, 'nn n1');
      expect(full.declination['Sing-Ind'], 'A-lag,a-lag');
      expect(full.description.single.tr['pl'], 'Pierwsza drużyna');
      expect(full.examples.single.orig, 'klubbens A-lag');
      expect(full.expressions.single.tr['en'], 'from A to B');
      expect(full.expressions.single.description.single.tr['en'], 'from one place to another');
      final bare = dictionary.lookup('abba')!;
      expect([bare.gender, bare.declination, bare.description, bare.examples, bare.expressions], ['', isEmpty, isEmpty, isEmpty, isEmpty]);
    });
  });

  group('colors', () {
    test('the first is green; all are distinct and readable on the app background, none is black', () {
      final background = ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff315f72)).colorScheme.surface;
      double contrast(Color a, Color b) {
        final x = a.computeLuminance(), y = b.computeLuminance();
        return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
      }
      final first = wordTranslationColors.first;
      expect(first.g > first.r && first.g > first.b, isTrue);
      expect(wordTranslationColors.toSet().length, wordTranslationColors.length);
      expect(wordTranslationColors, isNot(contains(Colors.black)));
      for (final c in wordTranslationColors) {
        expect(contrast(c, background), greaterThanOrEqualTo(4.5), reason: '$c');
        expect(contrast(c, Colors.white), greaterThanOrEqualTo(4.5), reason: '$c');
      }
    });
    test('the study language gets none; there is a color for every language', () {
      AppSettings.instance.textLanguages = const ['en', 'nb', 'uk'];
      expect(wordTranslationLanguages('nb'), {'en': wordTranslationColors[0], 'uk': wordTranslationColors[1]});
      AppSettings.instance.textLanguages = translationsLanguagesForTest;
      expect(wordTranslationLanguages('xx').values.toSet().length, translationsLanguagesForTest.length);
    });
  });

  group('saved dictionaries', () {
    late Directory tmp; late SavedDictionaries saved; late File file;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('saved');
      saved = SavedDictionaries(root: tmp.path);
      file = File(p.join(tmp.path, 'dictionaries', 'dict_nb.json'));
      await file.parent.create(recursive: true);
    });
    tearDown(() async { SavedDictionaries.instance = SavedDictionaries(); await tmp.delete(recursive: true); });

    test('only a saved file counts; it is read once, until forgotten', () async {
      expect(await saved.has('nb'), isFalse);
      await file.writeAsString(jsonEncode(sample));
      expect(await saved.has('nb'), isTrue);
      final first = await saved.load('nb');
      expect(first.lookup('abba')?.tr['uk'], 'Абба-uk');
      expect(await saved.load('nb'), same(first));
      saved.forget('nb');
      expect(await saved.load('nb'), isNot(same(first)));
    });

    test('a broken or missing file is an error, and is tried again next time', () async {
      await expectLater(saved.load('nb'), throwsA(isA<FileSystemException>()));
      await file.writeAsString('[1, 2]');
      await expectLater(saved.load('nb'), throwsA(isA<FormatException>()));
      await file.writeAsString('{not json');
      await expectLater(saved.load('nb'), throwsA(isA<FormatException>()));
      await file.writeAsString(jsonEncode(sample));
      expect((await saved.load('nb')).lookup('abba'), isNotNull);
    });

    test('removing a dictionary through the Dictionaries page forgets the copy in memory', () async {
      SavedDictionaries.instance = saved;
      await file.writeAsString(jsonEncode(sample));
      await saved.load('nb');
      await Dictionaries(Api(), root: tmp.path).remove('nb');
      await expectLater(saved.load('nb'), throwsA(isA<FileSystemException>()));
    });
  });

  group('the line in View and Play', () {
    late _FakeSaved saved;
    setUp(() {
      AppSettings.instance..audioLanguage = 'nb'..textLanguages = const ['en', 'nb', 'uk'];
      saved = _FakeSaved({'nb': WordDictionary(sample)});
      SavedDictionaries.instance = saved;
    });
    tearDown(() => SavedDictionaries.instance = SavedDictionaries());

    Future<void> show(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: ChapterViewScreen(chapter: chapter)));
      await tester.pump();
    }
    Future<void> toggle(WidgetTester tester) async { await tester.tap(find.byType(FilterChip)); await tester.pump(); await tester.pump(); }

    testWidgets('no dictionary for the language: no button', (tester) async {
      saved.dictionaries.clear();
      await show(tester);
      expect(find.text('Word translation'), findsNothing);
      expect(find.text('Abba, ukjent A-LAG!'), findsOneWidget);
    });

    testWidgets('the button starts off and loads nothing until toggled; toggling shows and hides the line', (tester) async {
      await show(tester);
      expect(find.widgetWithText(FilterChip, 'Word translation'), findsOneWidget);
      expect(tester.widget<FilterChip>(find.byType(FilterChip)).selected, isFalse);
      expect(find.text('Word translation'), findsOneWidget);
      expect(saved.loads, 0);
      expect(wordSpans(tester), isEmpty);

      await toggle(tester);
      expect(tester.widget<FilterChip>(find.byType(FilterChip)).selected, isTrue);
      expect(find.text('Word translation'), findsNWidgets(2));
      expect(wordSpans(tester), isNotEmpty);
      // Below the translations of the sentence.
      expect(tester.getTopLeft(find.text('Word translation').last).dy, greaterThan(tester.getTopLeft(find.text('Рядок один.')).dy));

      await toggle(tester);
      expect(find.text('Word translation'), findsOneWidget);
      expect(wordSpans(tester), isEmpty);
    });

    testWidgets('each known word is followed by its translations in their colors; the rest is unchanged', (tester) async {
      await show(tester);
      await toggle(tester);
      final green = wordTranslationColors[0], second = wordTranslationColors[1];
      final spans = wordSpans(tester);
      expect(spans.map((s) => s.text).join(), 'Abba Abba-en Абба-uk, ukjent A-LAG A team команда А!');
      Color? color(String text) => spans.firstWhere((s) => s.text == text).style?.color;
      expect(color(' Abba-en'), green);
      expect(color(' Абба-uk'), second);
      expect(color(' A team'), green);
      expect(color(' команда А'), second);
      // Words take the line's black; only known ones are clickable.
      expect(spans.firstWhere((s) => s.text == 'Abba').recognizer, isNotNull);
      expect(spans.firstWhere((s) => s.text == 'A-LAG').recognizer, isNotNull);
      expect(spans.firstWhere((s) => s.text!.contains('ukjent')).recognizer, isNull);
      final rich = tester.widgetList<RichText>(find.byType(RichText)).firstWhere((r) => r.text.toPlainText().contains('Abba-en'));
      expect(rich.text.style?.color, Colors.black);
    });

    testWidgets('a missing translation is skipped, and the other language keeps its color', (tester) async {
      await show(tester);
      await toggle(tester);
      await tester.tap(find.text('Next line'));
      await tester.pump();
      final spans = wordSpans(tester);
      expect(spans.map((s) => s.text).join(), 'tom порожній Abba Abba-en Абба-uk.');
      expect(spans.firstWhere((s) => s.text == ' порожній').style?.color, wordTranslationColors[1]);
    });

    testWidgets('the toggle stays on from line to line', (tester) async {
      await show(tester);
      await toggle(tester);
      await tester.tap(find.text('Next line'));
      await tester.pump();
      expect(tester.widget<FilterChip>(find.byType(FilterChip)).selected, isTrue);
      expect(saved.loads, 1);
    });

    testWidgets('the player\'s language decides: another language without a dictionary hides the button', (tester) async {
      Widget line(String language) => MaterialApp(home: Scaffold(body: ChapterLine(chapter: chapter, index: 0, total: 2, language: language)));
      await tester.pumpWidget(line('nb'));
      await tester.pump();
      await tester.tap(find.byType(FilterChip));
      await tester.pump(); await tester.pump();
      expect(wordSpans(tester), isNotEmpty);
      await tester.pumpWidget(line('en'));
      await tester.pump();
      expect(find.byType(FilterChip), findsNothing);
      expect(wordSpans(tester), isEmpty);
      await tester.pumpWidget(line('nb'));
      await tester.pump(); await tester.pump(); await tester.pump();
      expect(wordSpans(tester), isNotEmpty);
    });

    testWidgets('rebuilding keeps the clickable words, so a tap during playback isn\'t lost', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: WordTranslationLine(sentence: 'Abba', dictionary: saved.dictionaries['nb']!, languages: wordTranslationLanguages('nb')))));
      final before = wordSpans(tester).first.recognizer;
      expect(before, isA<TapGestureRecognizer>());
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: WordTranslationLine(sentence: 'Abba', dictionary: saved.dictionaries['nb']!, languages: wordTranslationLanguages('nb')))));
      expect(wordSpans(tester).first.recognizer, same(before));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: WordTranslationLine(sentence: 'Abba tom', dictionary: saved.dictionaries['nb']!, languages: wordTranslationLanguages('nb')))));
      expect(wordSpans(tester).first.recognizer, isNot(same(before)));
    });

    testWidgets('a dictionary that can\'t be read shows the error instead of the line', (tester) async {
      saved.loadError = const FormatException('The dictionary file is not valid');
      await show(tester);
      await toggle(tester);
      expect(find.text('The dictionary file is not valid'), findsOneWidget);
    });

    testWidgets('clicking a word opens its entry on a page of its own', (tester) async {
      await show(tester);
      await toggle(tester);
      await tester.tapOnText(find.textRange.ofSubstring('A-LAG').last); // the first is in the sentence itself
      await tester.pumpAndSettle();
      expect(find.byType(WordEntryScreen), findsOneWidget);
      expect(find.text('A-lag'), findsNWidgets(2)); // title and heading
      expect(find.text('Neuter n1'), findsOneWidget);
      expect(tester.widget<Text>(find.text('A team')).style?.color, wordTranslationColors[0]);
      expect(tester.widget<Text>(find.text('команда А')).style?.color, wordTranslationColors[1]);
      expect(find.text('A-Mannschaft'), findsNothing); // German is not a chosen language

      expect(find.text('Inflection'), findsOneWidget);
      expect(find.textContaining('Singular, indefinite: A-lag, a-lag'), findsOneWidget);
      expect(find.textContaining('Plural, definite: A-laga, A-lagene'), findsOneWidget);
      expect(find.textContaining('Other forms: a, à'), findsOneWidget);
      expect(find.textContaining('Future: x'), findsOneWidget);
      expect(find.text('Meanings'), findsNothing); // this entry has no senses
      expect(find.text('Definitions'), findsOneWidget);
      expect(find.text('førstelag'), findsOneWidget);
      expect(find.text('first team'), findsOneWidget);
      expect(find.text('Pierwsza drużyna'), findsNothing);
      await tester.scrollUntilVisible(find.text('from one place to another'), 200);
      expect(find.text('Examples'), findsOneWidget);
      expect(find.text('Expressions'), findsOneWidget);
      expect(find.text('fra A til B'), findsOneWidget);
      expect(find.text('from A to B'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(WordEntryScreen), findsNothing);
      expect(tester.widget<FilterChip>(find.byType(FilterChip)).selected, isTrue);
    });

    testWidgets('an entry with only translations shows no empty sections', (tester) async {
      await tester.pumpWidget(MaterialApp(home: WordEntryScreen(entry: WordDictionary(sample).lookup('abba')!, languages: wordTranslationLanguages('nb'))));
      expect(find.text('Abba-en'), findsOneWidget);
      for (final heading in ['Inflection', 'Meanings', 'Definitions', 'Examples', 'Expressions']) { expect(find.text(heading), findsNothing); }
    });

    testWidgets('senses are numbered, in the order of the file, with labels, translations and notes', (tester) async {
      AppSettings.instance.textLanguages = const ['en', 'nb', 'uk', 'pl'];
      await tester.pumpWidget(MaterialApp(home: WordEntryScreen(entry: WordDictionary(withSenses).lookup('a')!, languages: wordTranslationLanguages('nb'))));
      final en = wordTranslationColors[0], uk = wordTranslationColors[1], pl = wordTranslationColors[2];

      expect(find.text('Meanings'), findsOneWidget);
      expect(find.text('1. bokstavtegn og språklyd'), findsOneWidget);
      expect(find.text('2. sjette tone i C-durskalaen'), findsOneWidget);
      expect(find.text('3. beste karakter'), findsOneWidget);
      expect(tester.getTopLeft(find.text('1. bokstavtegn og språklyd')).dy, lessThan(tester.getTopLeft(find.text('2. sjette tone i C-durskalaen')).dy));
      expect(tester.getTopLeft(find.text('Meanings')).dy, lessThan(tester.getTopLeft(find.text('Definitions')).dy));

      expect(find.text('noun'), findsNWidgets(2));
      expect(find.text('noun · music'), findsOneWidget);
      expect(find.text('informal'), findsNothing); // labels come only from the sense
      expect(tester.widget<Text>(find.text('the letter a')).style?.color, en);
      expect(tester.widget<Text>(find.text('ля')).style?.color, uk);
      expect(tester.widget<Text>(find.text('a (dźwięk), la')).style?.color, pl); // several translations
      expect(tester.widget<Text>(find.text('Ukrainian uses the name ля, not the letter.')).style?.color, uk);

      // What is for checking, not for reading, stays hidden.
      expect(find.text('note'), findsNothing);
      expect(find.textContaining('[1]'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('translations and notes of languages not chosen are hidden', (tester) async {
      AppSettings.instance.textLanguages = const ['en', 'nb'];
      await tester.pumpWidget(MaterialApp(home: WordEntryScreen(entry: WordDictionary(withSenses).lookup('a')!, languages: wordTranslationLanguages('nb'))));
      expect(find.text('A (note)'), findsOneWidget);
      expect(find.text('ля'), findsNothing);
      expect(find.text('Ukrainian uses the name ля, not the letter.'), findsNothing);
      expect(find.text('2. sjette tone i C-durskalaen'), findsOneWidget);
    });

    testWidgets('a sense with little in it still shows cleanly', (tester) async {
      const entry = DictionaryEntry('x', {}, senses: [DictionarySense(register: 'dated')]);
      await tester.pumpWidget(MaterialApp(home: WordEntryScreen(entry: entry, languages: wordTranslationLanguages('nb'))));
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('dated'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

const translationsLanguagesForTest = ['en', 'nb', 'uk', 'ru', 'de', 'da', 'sv', 'cs', 'bg', 'pl', 'pt', 'es', 'fr', 'el', 'he', 'it'];
