import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import '../l10n/l10n.dart';

/// The file types a recording's own texts and timings can be read from.
const recordingTextsExtensions = ['.json', '.odt', '.srt', '.vtt'];

/// Language codes other programs use for one of ours ("cz" and "gr": LanguageTutor's files).
const _languageAliases = {'no': 'nb', 'nob': 'nb', 'nno': 'nn', 'cz': 'cs', 'gr': 'el'};
String _code(String key) => _languageAliases[key.trim().toLowerCase()] ?? key.trim().toLowerCase();
/// JSON keys of an item's start and (optional) end, in milliseconds.
const _startKeys = ['timeMs', 'startMs', 'time_ms', 'start_ms'];
const _endKeys = ['endMs', 'end_ms'];

/// A recording's sentences made by the user: per sentence its texts in one or more languages and its
/// start (and optionally end) in the audio. A missing end is set by the server: the next sentence's
/// start, or the end of the audio.
class RecordingTexts {
  const RecordingTexts(this.sentences, this.startMs, this.endMs, [this.language]);
  /// Language code → one text per sentence ('' where an item has none in that language).
  final Map<String, List<String>> sentences;
  final List<int> startMs;
  final List<int?> endMs;
  /// The language spoken in the media, when the file says it (LanguageTutor's JSON and ODT files).
  final String? language;
  int get count => startMs.length;
  /// [endMs] with every missing end filled in: the next sentence's start (the last one: [lastEndMs]).
  List<int> filledEnds(int lastEndMs) => [for (var i = 0; i < count; i++)
    endMs[i] ?? (i + 1 < count && startMs[i + 1] > startMs[i] ? startMs[i + 1] : lastEndMs)];
  /// The fields of the recording requests (mode "manual").
  Map<String, dynamic> toJson() => {'sentences': sentences, 'start_ms': startMs, 'end_ms': endMs};
}

/// Why a texts file can't be used: [key] and [args] give the translated message.
class RecordingTextsException implements Exception {
  const RecordingTextsException(this.key, [this.args = const {}]);
  final String key;
  final Map<String, Object?> args;
  String get message => trNow(key, args);
  @override String toString() => message;
}

/// Reads the file [fileName] with content [bytes]: by its extension an ODT document (as LanguageTutor
/// makes them), JSON, SRT or WebVTT. See [parseRecordingTexts].
RecordingTexts parseRecordingTextsBytes(String fileName, List<int> bytes, String language) {
  if (p.extension(fileName).toLowerCase() == '.odt') return parseOdtTexts(bytes, language);
  return parseRecordingTexts(fileName, utf8.decode(bytes, allowMalformed: true), language);
}

/// Reads [content] of the file [fileName]: by its extension JSON, SRT or WebVTT. The texts of SRT and
/// WebVTT are in [language], the language spoken in the media; JSON items must have a text in it.
/// LanguageTutor's JSON says which language its audio is in: [language] is used only if the file has
/// texts in it, and the result's [RecordingTexts.language] tells the one used.
RecordingTexts parseRecordingTexts(String fileName, String content, String language) {
  if (content.startsWith('﻿')) content = content.substring(1);
  return switch (p.extension(fileName).toLowerCase()) {
    '.json' => parseJsonTexts(content, language),
    '.srt' || '.vtt' => parseSubtitles(content, language),
    _ => throw const RecordingTextsException('textsUnsupportedFile'),
  };
}

/// A JSON list of items such as `{"nb": "Hei.", "en": "Hi.", "timeMs": 0}`: every key but the
/// times is a language code with that language's text of the sentence. Also `{"items": [...]}`,
/// and LanguageTutor's export (see [parseExportedJson]).
RecordingTexts parseJsonTexts(String content, String language) {
  Object? data;
  try { data = jsonDecode(content); }
  on FormatException catch (e) { throw RecordingTextsException('textsInvalidJson', {'error': e.message}); }
  if (data is Map && data['audio'] is Map && data['sentences'] is Map) return parseExportedJson(data, language);
  if (data is Map && data['items'] is List) data = data['items'];
  if (data is! List) throw const RecordingTextsException('textsNotList');
  final items = <(int, int?, Map<String, String>)>[];
  for (var i = 0; i < data.length; i++) {
    final item = data[i], number = i + 1;
    if (item is! Map) throw RecordingTextsException('textsNotList');
    int? time(List<String> keys, {required bool required}) {
      final key = keys.firstWhere(item.containsKey, orElse: () => '');
      final value = key.isEmpty ? null : item[key];
      if (value == null && !required) return null;
      if (value is! num || value < 0 || value != value.roundToDouble()) throw RecordingTextsException('textsItemTime', {'item': number});
      return value.toInt();
    }
    final start = time(_startKeys, required: true)!, end = time(_endKeys, required: false);
    final texts = <String, String>{};
    for (final e in item.entries) {
      final key = '${e.key}';
      if (_startKeys.contains(key) || _endKeys.contains(key)) continue;
      final code = _languageAliases[key.toLowerCase()] ?? key.toLowerCase();
      if (!languageNames.containsKey(code) || e.value is! String) throw RecordingTextsException('textsItemKey', {'item': number, 'key': key});
      texts[code] = (e.value as String).trim();
    }
    if ((texts[language] ?? '').isEmpty) {
      throw RecordingTextsException('textsItemMissing', {'item': number, 'language': languageNames[language] ?? language});
    }
    items.add((start, end, texts));
  }
  if (items.isEmpty) throw const RecordingTextsException('textsEmpty');
  mergeSort(items, (a, b) => a.$1.compareTo(b.$1));
  final codes = orderedLanguages({for (final item in items) ...item.$3.keys});
  return RecordingTexts({for (final code in codes) code: [for (final item in items) item.$3[code] ?? '']},
    [for (final item in items) item.$1], [for (final item in items) item.$2]);
}

/// LanguageTutor's JSON export (its audio URL and key are ignored: the media is the one chosen here):
/// `{"audio": {"nb": {"start_ms": [0, 100], "end_ms": [100, 200], ...}},
///   "sentences": {"nb": ["line 1", "line 2"], "en": [...]}}`
/// The audio's language is the one in "audio" ([language] if it is there).
RecordingTexts parseExportedJson(Map data, String language) {
  final audio = {for (final e in (data['audio'] as Map).entries) _code('${e.key}'): e.value};
  final timed = [for (final e in audio.entries) if (e.value is Map && (e.value as Map)['start_ms'] is List) e.key];
  if (timed.isEmpty) throw const RecordingTextsException('textsNoTimings');
  final main = timed.contains(language) ? language : timed.first;
  final entry = audio[main] as Map;
  List<int?> times(Object? list, String key) {
    if (list == null) return const [];
    if (list is! List) throw RecordingTextsException('textsBadTiming', {'item': 1});
    return [for (var i = 0; i < list.length; i++) switch (list[i]) {
      null => null,
      num v when v >= 0 && v == v.roundToDouble() => v.toInt(),
      _ => throw RecordingTextsException('textsBadTiming', {'item': i + 1}),
    }];
  }
  final starts = times(entry['start_ms'], 'start_ms'), ends = times(entry['end_ms'], 'end_ms');
  if (starts.any((s) => s == null)) throw RecordingTextsException('textsBadTiming', {'item': starts.indexOf(null) + 1});
  final texts = <String, List<String>>{};
  for (final e in (data['sentences'] as Map).entries) {
    final code = _code('${e.key}');
    if (!languageNames.containsKey(code)) throw RecordingTextsException('textsUnknownLanguage', {'key': '${e.key}'});
    if (e.value is! List) throw const RecordingTextsException('textsNotList');
    texts[code] = [for (final t in e.value as List) t == null ? '' : '$t'.trim()];
  }
  return _timedTexts(texts, main, starts.cast<int>(), [for (var i = 0; i < starts.length; i++) i < ends.length ? ends[i] : null]);
}

/// An ODT document as LanguageTutor makes it: a line "Audio: ..." (ignored) and a table whose header row
/// is "Time" and the language codes (the first one is the audio's language), then one row per sentence:
/// the time its audio ends ("m:ss.cc") and its text in each language. A sentence starts where the one
/// before ends (the first at 0).
RecordingTexts parseOdtTexts(List<int> bytes, String language) {
  final XmlDocument document;
  try {
    final content = ZipDecoder().decodeBytes(bytes).findFile('content.xml');
    if (content == null) throw const FormatException();
    document = XmlDocument.parse(utf8.decode(content.content, allowMalformed: true));
  } catch (_) { throw const RecordingTextsException('textsInvalidOdt'); }

  for (final table in document.findAllElements('table:table')) {
    final rows = [for (final row in table.findAllElements('table:table-row')) _odtCells(row)];
    final header = rows.indexWhere((r) => r.isNotEmpty && r.first.trim().toLowerCase() == 'time');
    if (header < 0) continue;
    final codes = [for (final c in rows[header].skip(1)) _code(c)];
    while (codes.isNotEmpty && codes.last.isEmpty) { codes.removeLast(); }
    if (codes.isEmpty) continue;
    for (final c in codes) {
      if (!languageNames.containsKey(c)) throw RecordingTextsException('textsUnknownLanguage', {'key': c});
    }
    final texts = {for (final c in codes) c: <String>[]};
    final ends = <int?>[];
    for (final row in rows.skip(header + 1)) {
      String cell(int i) => i < row.length ? row[i].trim() : '';
      final line = [for (var i = 0; i < codes.length; i++) cell(i + 1)];
      final time = cell(0);
      if (time.isEmpty && line.every((t) => t.isEmpty)) continue; // an empty row
      if (time.toLowerCase() == 'time') continue; // the header again (a table's column names, then its first row)
      final ms = time.isEmpty ? null : _odtTime(time);
      if (time.isNotEmpty && ms == null) throw RecordingTextsException('textsBadTiming', {'item': ends.length + 1});
      ends.add(ms);
      for (var i = 0; i < codes.length; i++) { texts[codes[i]]!.add(line[i]); }
    }
    final main = codes.contains(language) ? language : codes.first;
    // Rows without a time at the end: their audio isn't marked yet.
    final timed = ends.lastIndexWhere((e) => e != null) + 1;
    if (ends.take(timed).contains(null)) throw RecordingTextsException('textsBadTiming', {'item': ends.indexOf(null) + 1});
    final endTimes = ends.take(timed).cast<int>().toList();
    final starts = [for (var i = 0; i < endTimes.length; i++) i == 0 ? 0 : endTimes[i - 1]];
    return _timedTexts(texts, main, starts, endTimes);
  }
  throw const RecordingTextsException('textsOdtNoTable');
}

/// The texts of one table row's cells, with repeated cells expanded.
List<String> _odtCells(XmlElement row) {
  final cells = <String>[];
  for (final cell in row.childElements) {
    if (cell.name.qualified != 'table:table-cell' && cell.name.qualified != 'table:covered-table-cell') continue;
    final repeat = (int.tryParse(cell.getAttribute('table:number-columns-repeated') ?? '') ?? 1).clamp(1, 50);
    final text = [for (final para in cell.findAllElements('text:p')) _odtText(para)].join('\n');
    for (var i = 0; i < repeat; i++) { cells.add(text); }
  }
  return cells;
}

/// The text of a paragraph, with ODT's spaces, tabs and line breaks.
String _odtText(XmlNode node) {
  final out = StringBuffer();
  for (final child in node.children) {
    if (child is XmlText) { out.write(child.value); }
    else if (child is XmlElement) {
      switch (child.name.qualified) {
        case 'text:s': out.write(' ' * (int.tryParse(child.getAttribute('text:c') ?? '') ?? 1));
        case 'text:tab': out.write('\t');
        case 'text:line-break': out.write(' ');
        default: out.write(_odtText(child));
      }
    }
  }
  return out.toString();
}

/// LanguageTutor's time "m:ss.cc" (also "h:mm:ss.cc", "ss.ccc") → milliseconds; null if it isn't one.
int? _odtTime(String text) {
  final m = RegExp(r'^(?:(\d+):)?(?:(\d+):)?(\d+)(?:[.,](\d{1,3}))?$').firstMatch(text.replaceAll(' ', ''));
  if (m == null) return null;
  final parts = [m.group(1), m.group(2)].whereType<String>().map(int.parse).toList();
  var minutes = 0;
  for (final part in parts) { minutes = minutes * 60 + part; }
  final fraction = m.group(4) ?? '';
  return (minutes * 60 + int.parse(m.group(3)!)) * 1000 + (fraction.isEmpty ? 0 : int.parse(fraction.padRight(3, '0')));
}

/// Checks a file's timed sentences: [starts] ascending, every given end after its start, texts in [main]
/// for every timed sentence; lines of other languages beyond the timed ones are dropped (they are empty)
/// and short lists are padded with ''.
RecordingTexts _timedTexts(Map<String, List<String>> texts, String main, List<int> starts, List<int?> ends) {
  final count = starts.length;
  if (count == 0) throw const RecordingTextsException('textsEmpty');
  for (var i = 0; i < count; i++) {
    final end = ends[i];
    if ((i > 0 && starts[i] < starts[i - 1]) || (end != null && end <= starts[i])) {
      throw RecordingTextsException('textsBadTiming', {'item': i + 1});
    }
  }
  final mainTexts = texts[main] ?? const [];
  final untimed = mainTexts.skip(count).where((t) => t.isNotEmpty).length;
  if (untimed > 0) throw RecordingTextsException('textsMissingTimes', {'count': untimed});
  if (!mainTexts.take(count).any((t) => t.isNotEmpty)) {
    throw RecordingTextsException('textsNoLanguageText', {'language': languageNames[main] ?? main});
  }
  final codes = orderedLanguages(texts.keys);
  return RecordingTexts({
    for (final c in codes) if (texts[c]!.take(count).any((t) => t.isNotEmpty))
      c: [for (var i = 0; i < count; i++) i < texts[c]!.length ? texts[c]![i] : ''],
  }, starts, ends, main);
}

/// A stable sort (List.sort isn't), so items starting together keep their order.
void mergeSort<T>(List<T> list, int Function(T, T) compare) {
  if (list.length < 2) return;
  final middle = list.length ~/ 2;
  final left = list.sublist(0, middle), right = list.sublist(middle);
  mergeSort(left, compare); mergeSort(right, compare);
  var i = 0, j = 0, k = 0;
  while (i < left.length && j < right.length) { list[k++] = compare(right[j], left[i]) < 0 ? right[j++] : left[i++]; }
  while (i < left.length) { list[k++] = left[i++]; }
  while (j < right.length) { list[k++] = right[j++]; }
}

final _cueTime = RegExp(r'^\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})');
final _tag = RegExp(r'<[^>]*>');

/// SRT or WebVTT cues, as sentences in [language].
RecordingTexts parseSubtitles(String content, String language) {
  final blocks = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split(RegExp(r'\n\s*\n'));
  final starts = <int>[], ends = <int?>[], texts = <String>[];
  var cue = 0;
  for (final block in blocks) {
    final lines = block.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final timeLine = lines.indexWhere((l) => l.contains('-->'));
    if (timeLine < 0) continue; // a header ("WEBVTT"), NOTE, STYLE, or a stray line
    cue++;
    final m = _cueTime.firstMatch(lines[timeLine]);
    if (m == null) throw RecordingTextsException('textsInvalidSubtitles', {'item': cue});
    final text = lines.skip(timeLine + 1).map((l) => l.replaceAll(_tag, '').trim()).where((l) => l.isNotEmpty).join(' ');
    if (text.isEmpty) continue;
    starts.add(_ms(m.group(1)!)); ends.add(_ms(m.group(2)!)); texts.add(text);
  }
  if (starts.isEmpty) throw const RecordingTextsException('textsEmpty');
  return RecordingTexts({language: texts}, starts, ends);
}

/// "01:02:03,450", "02:03.450" → milliseconds.
int _ms(String time) {
  final parts = time.replaceAll(',', '.').split(':');
  final seconds = double.parse(parts.last);
  var minutes = 0;
  for (final part in parts.take(parts.length - 1)) { minutes = minutes * 60 + int.parse(part); }
  return minutes * 60000 + (seconds * 1000).round();
}
