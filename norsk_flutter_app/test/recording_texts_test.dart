import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/services/recording_texts.dart';

void main() {
  test('JSON items give the texts in every language, sorted by start', () {
    final t = parseRecordingTexts('lesson.json', '''﻿[
      {"en": "Good day.", "no": "God dag.", "timeMs": 1450, "endMs": 2750},
      {"nb": "Hei.", "en": "Hi.", "uk": "Привіт.", "timeMs": 0}
    ]''', 'nb');
    expect(t.startMs, [0, 1450]);
    expect(t.endMs, [null, 2750]);
    expect(t.sentences, {'en': ['Hi.', 'Good day.'], 'nb': ['Hei.', 'God dag.'], 'uk': ['Привіт.', '']});
    expect(t.toJson()['start_ms'], [0, 1450]);
  });

  test('JSON errors name the item', () {
    Matcher fails(String key) => throwsA(isA<RecordingTextsException>().having((e) => e.key, 'key', key));
    expect(() => parseRecordingTexts('a.json', '{', 'nb'), fails('textsInvalidJson'));
    expect(() => parseRecordingTexts('a.json', '{"a": 1}', 'nb'), fails('textsNotList'));
    expect(() => parseRecordingTexts('a.json', '[]', 'nb'), fails('textsEmpty'));
    expect(() => parseRecordingTexts('a.json', '[{"nb": "Hei."}]', 'nb'), fails('textsItemTime'));
    expect(() => parseRecordingTexts('a.json', '[{"nb": "Hei.", "timeMs": 1.5}]', 'nb'), fails('textsItemTime'));
    expect(() => parseRecordingTexts('a.json', '[{"en": "Hi.", "timeMs": 0}]', 'nb'), fails('textsItemMissing'));
    expect(() => parseRecordingTexts('a.json', '[{"nb": "Hei.", "xx": "?", "timeMs": 0}]', 'nb'), fails('textsItemKey'));
    expect(() => parseRecordingTexts('a.txt', '', 'nb'), fails('textsUnsupportedFile'));
  });

  test('SRT and WebVTT cues are sentences in the media language', () {
    final srt = parseRecordingTexts('a.srt', '1\r\n00:00:01,000 --> 00:00:02,500\r\nHei <i>du</i>.\r\n\r\n2\r\n01:00:03,000 --> 01:00:04,000\r\nGod\r\ndag.\r\n', 'nb');
    expect(srt.sentences, {'nb': ['Hei du.', 'God dag.']});
    expect(srt.startMs, [1000, 3603000]);
    expect(srt.endMs, [2500, 3604000]);

    final vtt = parseRecordingTexts('a.vtt', 'WEBVTT\n\nNOTE made by hand\n\nintro\n00:01.200 --> 00:02.000 align:start\nHi.\n', 'en');
    expect(vtt.sentences, {'en': ['Hi.']});
    expect(vtt.startMs, [1200]);
    expect(vtt.endMs, [2000]);
  });
}
