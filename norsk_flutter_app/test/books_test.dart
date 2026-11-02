import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/l10n/l10n.dart';
import 'package:norsk_audio_groups/models/entities.dart';
import 'package:norsk_audio_groups/screens/books_screen.dart';
import 'package:norsk_audio_groups/screens/chapters_screen.dart';
import 'package:norsk_audio_groups/services/api.dart';
import 'package:norsk_audio_groups/services/settings.dart';

void main() {
  test("an audio's url is kept when the chapter is saved and loaded, and resolved against the server", () {
    final chapter = Recording.fromJson({'id': 'c', 'name': '1', 'sectionId': 's', 'audio': {
      'nb': {'url': 'http://audio.example/nb/MAT/1', 'start_ms': [0], 'end_ms': [900]},
      'en': {'url': '/files/en.mp3', 'start_ms': [0], 'end_ms': [900]},
      'de': {'audio_key': 'hidden', 'start_ms': [0], 'end_ms': [900]}}, 'sentences': {}});
    final saved = chapter.withAudio({...chapter.audio, 'nb': chapter.audio['nb']!.withLocalFile('nb.mp3')});
    final loaded = Recording.fromJson(jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>);
    expect(loaded.audio['nb']!.url, 'http://audio.example/nb/MAT/1');
    expect(loaded.audio['nb']!.localFile, 'nb.mp3');
    final api = Api()..baseUrl = 'https://server.example';
    expect(api.externalAudioUrl(loaded, 'nb'), 'http://audio.example/nb/MAT/1');
    expect(api.externalAudioUrl(loaded, 'en'), 'https://server.example/files/en.mp3');
    expect(api.externalAudioUrl(loaded, 'de'), isNull);
  });
  test('name in the UI language, else English, else the first available', () {
    final book = Book.fromJson({'id': 'b', 'name': {'nb': 'Bibelen', 'en': 'Bible'}, 'author': '', 'audioLanguages': ['nb'], 'groups': [], 'icon': ''});
    expect(book.displayName('nb'), 'Bibelen');
    expect(book.displayName('de'), 'Bible');
    final noEnglish = Book.fromJson({'id': 'c', 'name': {'uk': 'Кобзар', 'pl': 'Kobziarz'}});
    expect(noEnglish.displayName('de'), 'Кобзар');
    expect(noEnglish.audioLanguages, isEmpty);
  });

  test('a page of books', () {
    final page = PagedList.fromJson({'items': [{'id': 'b', 'name': {'en': 'Bible'}}], 'total': 41, 'page': 3, 'page_size': 20}, Book.fromJson);
    expect(page.items.single.id, 'b');
    expect(page.pages, 3);
  });

  test('sections are books with a bookId; chapters are recordings with a sectionId', () {
    final section = Section.fromJson({'id': 's', 'bookId': 'bible', 'name': {'nb': 'Første Mosebok'}, 'audioLanguages': ['nb']});
    expect(section.bookId, 'bible');
    expect(section.displayName('en'), 'Første Mosebok');
    final chapter = Recording.fromJson({'id': 'c', 'sectionId': 's', 'name': 'Kapittel 1',
      'audio': {'nb': {'status': 'ready', 'duration_seconds': 2.0, 'start_ms': [0], 'end_ms': [1500]}},
      'sentences': {'nb': ['I begynnelsen.']}});
    expect(chapter.isChapter, isTrue);
    expect(chapter.groupId, '');
    expect(chapter.timedSentences('nb').single.endMs, 1500);
    expect(Recording.fromJson({'id': 'r', 'group_id': 'g', 'name': 'R'}).isChapter, isFalse);
  });

  testWidgets('a card with every audio language fits its grid cell', (tester) async {
    final book = Book('bible', const {'en': 'A rather long book name that needs two lines'}, 'Some Author',
      languageNames.keys.toList(), const [], '');
    await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(width: 160, height: 290,
      child: BookCard(api: Api(), book: book)))));
    expect(tester.takeException(), isNull);
    expect(find.text('NB'), findsOneWidget);
  });

  test('a saved chapter keeps everything, including its local audio files', () {
    final chapter = Recording.fromJson({'id': 'c', 'sectionId': 's', 'name': 'Kapittel 1',
      'audio': {'nb': {'status': 'ready', 'created_at': '2026-01-01', 'duration_seconds': 2.0, 'start_ms': [0], 'end_ms': [1500]}},
      'sentences': {'nb': ['I begynnelsen.'], 'en': ['In the beginning.']}});
    final saved = chapter.withAudio({'nb': chapter.audio['nb']!.withLocalFile('nb.mp3')});
    final copy = Recording.fromJson(jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>);
    expect(copy.sectionId, 's');
    expect(copy.audio['nb']!.localFile, 'nb.mp3');
    expect(copy.audio['nb']!.createdAt, '2026-01-01');
    expect(copy.timedSentences('nb').single.endMs, 1500);
    expect(copy.text('en', 0), 'In the beginning.');
  });

  test('the player shows the played audio language as the main line, when it has text', () {
    AppSettings.instance..audioLanguage = 'nb'..textLanguages = const ['en', 'nb'];
    const chapter = Recording('c', '', 'K', {}, {'nb': ['Linje.'], 'en': ['Line.'], 'de': ['']}, 's');
    expect(ChapterLine.mainLanguage(chapter), 'nb');
    expect(ChapterLine.mainLanguage(chapter, 'en'), 'en');
    expect(ChapterLine.mainLanguage(chapter, 'de'), 'nb');
    expect(ChapterLine.translationLanguages(chapter, 'en'), ['nb']);
  });

  testWidgets('a saved chapter is viewed one line at a time, with translations', (tester) async {
    AppSettings.instance..audioLanguage = 'nb'..textLanguages = const ['en', 'nb'];
    const chapter = Recording('c', '', 'Kapittel 1', {}, {'nb': ['Linje en.', 'Linje to.'], 'en': ['Line one.', 'Line two.'], 'de': ['Zeile eins.', 'Zeile zwei.']}, 's');
    await tester.pumpWidget(const MaterialApp(home: ChapterViewScreen(chapter: chapter)));
    expect(find.text('Linje en.'), findsOneWidget);
    expect(find.text('Line one.'), findsOneWidget);
    expect(find.text('Zeile eins.'), findsNothing);
    await tester.tap(find.text('Next line'));
    await tester.pump();
    expect(find.text('Linje to.'), findsOneWidget);
    expect(find.text('Line 2 of 2'), findsOneWidget);
    await tester.tap(find.text('Previous line'));
    await tester.pump();
    expect(find.text('Linje en.'), findsOneWidget);
  });
}
