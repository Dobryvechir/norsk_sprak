import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/services/recording_texts.dart';

Matcher fails(String key) => throwsA(isA<RecordingTextsException>().having((e) => e.key, 'key', key));

/// An .odt as LanguageTutor (NetOdt) makes it: "Audio: ..." and a table "Time" + language codes,
/// then per sentence the time its audio ends ("m:ss.cc") and its texts.
List<int> odt(List<List<String>> rows, {bool repeatedEmptyCell = false}) {
  String cell(String text) => '<table:table-cell office:value-type="string"><text:p>${const HtmlEscape().convert(text)}</text:p></table:table-cell>';
  final body = [
    for (final row in rows) '<table:table-row>${row.map(cell).join()}'
      '${repeatedEmptyCell ? '<table:table-cell table:number-columns-repeated="2"/>' : ''}</table:table-row>',
  ].join();
  final xml = '<?xml version="1.0" encoding="UTF-8"?><office:document-content '
    'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
    'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text>'
    '<text:p>Audio: https://example.com/a.mp3</text:p><text:p/>'
    '<table:table table:name="Table"><table:table-column table:number-columns-repeated="3"/>$body</table:table>'
    '</office:text></office:body></office:document-content>';
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/vnd.oasis.opendocument.text'))
    ..addFile(ArchiveFile.bytes('content.xml', utf8.encode(xml)));
  return ZipEncoder().encode(archive);
}

void main() {
  test("LanguageTutor's JSON gives the texts, timings and the audio's language; its URL is ignored", () {
    final t = parseRecordingTexts('lesson.json', jsonEncode({
      'audio': {'nb': {'url': 'https://example.com/a.mp3', 'audio_key': 'lesson', 'start_ms': [0, 1500, 3000], 'end_ms': [1500, 3000, 4200]}},
      'sentences': {'nb': ['Hei.', 'God dag.', 'Ha det.'], 'cz': ['Ahoj.', 'Dobrý den.'], 'gr': ['', '', ''], 'en': ['Hi.', 'Good day.', 'Bye.', '']},
    }), 'en');
    expect(t.language, 'nb'); // en has no audio in the file
    expect(t.startMs, [0, 1500, 3000]);
    expect(t.endMs, [1500, 3000, 4200]);
    // "cz" → cs (padded), "gr" (no text) left out, the empty line past the timings dropped.
    expect(t.sentences, {'nb': ['Hei.', 'God dag.', 'Ha det.'], 'en': ['Hi.', 'Good day.', 'Bye.'], 'cs': ['Ahoj.', 'Dobrý den.', '']});
    expect(t.toJson()['start_ms'], [0, 1500, 3000]);
  });

  test("LanguageTutor's JSON problems are explained", () {
    String file({List<Object?>? starts, List<Object?>? ends, Map<String, Object?>? sentences}) => jsonEncode({
      'audio': {'nb': {'start_ms': starts ?? [0, 100], 'end_ms': ends ?? [100, 200]}},
      'sentences': sentences ?? {'nb': ['A', 'B']},
    });
    expect(() => parseRecordingTexts('a.json', jsonEncode({'audio': {'nb': {}}, 'sentences': {}}), 'nb'), fails('textsNoTimings'));
    expect(() => parseRecordingTexts('a.json', file(starts: [0, 1.5]), 'nb'), fails('textsBadTiming'));
    expect(() => parseRecordingTexts('a.json', file(starts: [100, 0]), 'nb'), fails('textsBadTiming'));
    expect(() => parseRecordingTexts('a.json', file(ends: [0, 200]), 'nb'), fails('textsBadTiming'));
    expect(() => parseRecordingTexts('a.json', file(sentences: {'nb': ['A', 'B', 'C']}), 'nb'), fails('textsMissingTimes'));
    expect(() => parseRecordingTexts('a.json', file(sentences: {'nb': ['', ''], 'en': ['A', 'B']}), 'nb'), fails('textsNoLanguageText'));
    expect(() => parseRecordingTexts('a.json', file(sentences: {'nb': ['A', 'B'], 'xx': ['?']}), 'nb'), fails('textsUnknownLanguage'));
  });

  test('a missing end is the next start, or the given end of the last sentence', () {
    final t = parseRecordingTexts('a.json', jsonEncode({'audio': {'nb': {'start_ms': [0, 1000]}}, 'sentences': {'nb': ['A', 'B']}}), 'nb');
    expect(t.endMs, [null, null]);
    expect(t.filledEnds(5000), [1000, 5000]);
  });

  test("LanguageTutor's ODT: the first language column is the audio's, sentences start where the one before ends", () {
    final bytes = odt([
      ['Time', 'nb', 'uk', 'en'],
      ['Time', 'nb', 'uk', 'en'], // the header may be written twice
      ['0:01.50', 'Hei.', 'Привіт.', 'Hi.'],
      ['0:03.05', 'God dag.', 'Добрий день.', ''],
      ['1:02.5', 'Ha det.', 'Бувай.', 'Bye.'],
      ['', '', '', ''],
    ], repeatedEmptyCell: true);
    final t = parseRecordingTextsBytes('lesson.odt', bytes, 'de');
    expect(t.language, 'nb');
    expect(t.startMs, [0, 1500, 3050]);
    expect(t.endMs, [1500, 3050, 62500]);
    expect(t.sentences, {'nb': ['Hei.', 'God dag.', 'Ha det.'], 'en': ['Hi.', '', 'Bye.'], 'uk': ['Привіт.', 'Добрий день.', 'Бувай.']});

    // Another of its languages may be chosen as the audio's.
    expect(parseRecordingTextsBytes('lesson.odt', bytes, 'uk').language, 'uk');
  });

  test('ODT problems are explained', () {
    expect(() => parseRecordingTextsBytes('a.odt', utf8.encode('not a zip'), 'nb'), fails('textsInvalidOdt'));
    expect(() => parseRecordingTextsBytes('a.odt', odt([['When', 'nb'], ['0:01.00', 'A']]), 'nb'), fails('textsOdtNoTable'));
    expect(() => parseRecordingTextsBytes('a.odt', odt([['Time', 'nb'], ['soon', 'A']]), 'nb'), fails('textsBadTiming'));
    expect(() => parseRecordingTextsBytes('a.odt', odt([['Time', 'nb'], ['0:02.00', 'A'], ['0:01.00', 'B']]), 'nb'), fails('textsBadTiming'));
    // Lines whose audio isn't marked yet.
    expect(() => parseRecordingTextsBytes('a.odt', odt([['Time', 'nb'], ['0:01.00', 'A'], ['', 'B']]), 'nb'), fails('textsMissingTimes'));
  });
}
