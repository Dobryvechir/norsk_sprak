import 'dart:convert';
import 'package:path/path.dart' as p;
import '../l10n/l10n.dart';

/// The file types a recording's own texts and timings can be read from.
const recordingTextsExtensions = ['.json', '.srt', '.vtt'];

/// Language codes other programs use for one of ours.
const _languageAliases = {'no': 'nb', 'nob': 'nb', 'nno': 'nn'};
/// JSON keys of an item's start and (optional) end, in milliseconds.
const _startKeys = ['timeMs', 'startMs', 'time_ms', 'start_ms'];
const _endKeys = ['endMs', 'end_ms'];

/// A recording's sentences made by the user: per sentence its texts in one or more languages and its
/// start (and optionally end) in the audio. A missing end is set by the server: the next sentence's
/// start, or the end of the audio.
class RecordingTexts {
  const RecordingTexts(this.sentences, this.startMs, this.endMs);
  /// Language code → one text per sentence ('' where an item has none in that language).
  final Map<String, List<String>> sentences;
  final List<int> startMs;
  final List<int?> endMs;
  int get count => startMs.length;
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

/// Reads [content] of the file [fileName]: by its extension JSON, SRT or WebVTT. The texts of SRT and
/// WebVTT are in [language], the language spoken in the media; JSON items must have a text in it.
RecordingTexts parseRecordingTexts(String fileName, String content, String language) {
  if (content.startsWith('﻿')) content = content.substring(1);
  return switch (p.extension(fileName).toLowerCase()) {
    '.json' => parseJsonTexts(content, language),
    '.srt' || '.vtt' => parseSubtitles(content, language),
    _ => throw const RecordingTextsException('textsUnsupportedFile'),
  };
}

/// A JSON list of items such as `{"nb": "Hei.", "en": "Hi.", "timeMs": 0}`: every key but the
/// times is a language code with that language's text of the sentence. Also `{"items": [...]}`.
RecordingTexts parseJsonTexts(String content, String language) {
  Object? data;
  try { data = jsonDecode(content); }
  on FormatException catch (e) { throw RecordingTextsException('textsInvalidJson', {'error': e.message}); }
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
