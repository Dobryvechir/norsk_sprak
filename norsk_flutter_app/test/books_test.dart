import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/l10n/l10n.dart';
import 'package:norsk_audio_groups/models/entities.dart';
import 'package:norsk_audio_groups/screens/books_screen.dart';
import 'package:norsk_audio_groups/services/api.dart';

void main() {
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
}
