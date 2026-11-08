/// A text in the dictionary's language with its translations by language.
class DictionaryText {
  final String orig;
  final Map<String, String> tr;
  const DictionaryText(this.orig, this.tr);
  factory DictionaryText.fromJson(Map<dynamic, dynamic> j) => DictionaryText('${j['orig'] ?? ''}', _strings(j['tr']));
}

/// A fixed expression with the word: `orig`, its translation (`tran`) and what it means (`description`).
class DictionaryExpression {
  final String orig;
  final Map<String, String> tr;
  final List<DictionaryText> description;
  const DictionaryExpression(this.orig, this.tr, this.description);
  factory DictionaryExpression.fromJson(Map<dynamic, dynamic> j) {
    final tran = j['tran'];
    return DictionaryExpression('${j['orig'] ?? ''}', tran is Map ? _strings(tran['tr']) : const {}, _texts(j['description']));
  }
}

/// One meaning of a word, with its translations for that meaning, the best first:
///
///     {"id": "note", "pos": "noun", "domain": "music", "register": "formal", "gloss": "...", "from": [1],
///      "tr": {"uk": ["ля"], "pl": ["a (dźwięk)", "la"]}, "notes": {"uk": "..."}}
class DictionarySense {
  /// [id] names the sense; [from] lists the `description` items it is based on.
  final String id, pos, domain, register, gloss;
  final List<int> from;
  final Map<String, List<String>> tr;
  /// By language: what a learner of that language should watch out for.
  final Map<String, String> notes;
  const DictionarySense({this.id = '', this.pos = '', this.domain = '', this.register = '', this.gloss = '',
    this.from = const [], this.tr = const {}, this.notes = const {}});
  factory DictionarySense.fromJson(Map<dynamic, dynamic> j) => DictionarySense(
    id: '${j['id'] ?? ''}', pos: '${j['pos'] ?? ''}', domain: '${j['domain'] ?? ''}', register: '${j['register'] ?? ''}', gloss: '${j['gloss'] ?? ''}',
    from: [for (final i in _list(j['from'])) if (i is num) i.toInt()], tr: _stringLists(j['tr']), notes: _strings(j['notes']));
}

/// One word of a dictionary file. Every field but `or` and `tr` is often missing:
///
///     {"or": "A-lag", "tr": {"en": "...", "uk": "..."}, "gender": "nn n1",
///      "senses": [see DictionarySense],
///      "declination": {"Sing-Ind": "A-lag,a-lag", "Sing-Def": "...", "Plur-Ind": "...", "Plur-Def": "...", "": "..."},
///      "description": [{"orig": "...", "tr": {...}}], "deepDescription": [{"orig": "...", "tr": {...}}],
///      "expression": [{"orig": "...", "tran": {"orig": "...", "tr": {...}}, "description": [{"orig": "...", "tr": {...}}]}]}
class DictionaryEntry {
  /// The word as it is normally written, e.g. with a capital letter (the key is in lower case).
  final String original;
  final Map<String, String> tr;
  final String gender;
  /// The word's forms by grammatical form; several variants of one form are separated by commas.
  final Map<String, String> declination;
  /// Its meanings ([description]) and examples of its use ([examples]: `deepDescription` in the file).
  final List<DictionaryText> description, examples;
  final List<DictionaryExpression> expressions;
  /// Its meanings one by one, the most common first.
  final List<DictionarySense> senses;
  const DictionaryEntry(this.original, this.tr, {this.gender = '', this.declination = const {},
    this.description = const [], this.examples = const [], this.expressions = const [], this.senses = const []});

  factory DictionaryEntry.fromJson(String key, Map<dynamic, dynamic> j) => DictionaryEntry(
    '${j['or'] ?? key}', _strings(j['tr']), gender: '${j['gender'] ?? ''}', declination: _strings(j['declination']),
    description: _texts(j['description']), examples: _texts(j['deepDescription']),
    expressions: [for (final e in _list(j['expression'])) if (e is Map) DictionaryExpression.fromJson(e)],
    senses: [for (final s in _list(j['senses'])) if (s is Map) DictionarySense.fromJson(s)]);
}

Map<String, String> _strings(Object? json) =>
  json is Map ? {for (final e in json.entries) if (e.value != null) '${e.key}': '${e.value}'} : const {};
/// Lists of strings by key; a single string counts as a list of one.
Map<String, List<String>> _stringLists(Object? json) => json is Map ? {
  for (final e in json.entries)
    if (e.value is List) '${e.key}': [for (final s in e.value as List) if (s != null) '$s']
    else if (e.value != null) '${e.key}': ['${e.value}'],
} : const {};
List<dynamic> _list(Object? json) => json is List ? json : const [];
List<DictionaryText> _texts(Object? json) => [for (final e in _list(json)) if (e is Map) DictionaryText.fromJson(e)];

/// A piece of a sentence: a word found in the dictionary ([entry] set), or any other text (an unknown
/// word, spaces, punctuation), in the sentence's own spelling.
class SentencePart {
  final String text;
  final DictionaryEntry? entry;
  const SentencePart(this.text, [this.entry]);
}

/// A parsed dictionary file: words in lower case mapped to their entries.
class WordDictionary {
  /// Letters and digits; a hyphen or an apostrophe inside a word belongs to it ("A-laget", "Abde’els").
  static final _word = RegExp(r"[\p{L}\p{M}\p{N}]+(?:[-'’][\p{L}\p{M}\p{N}]+)*", unicode: true);
  final Map<String, dynamic> _entries;
  final _parsed = <String, DictionaryEntry?>{};
  WordDictionary(this._entries);

  /// The entry of [word] in any case. Sentences and the dictionary may differ in the kind of apostrophe.
  DictionaryEntry? lookup(String word) {
    final lower = word.toLowerCase();
    return _entry(lower) ?? _entry(lower.replaceAll("'", '’')) ?? _entry(lower.replaceAll('’', "'"));
  }

  DictionaryEntry? _entry(String key) => _parsed.putIfAbsent(key, () {
    final json = _entries[key];
    return json is Map ? DictionaryEntry.fromJson(key, json) : null;
  });

  /// [sentence] cut into pieces that, put together again, give the same sentence.
  List<SentencePart> analyze(String sentence) {
    final parts = <SentencePart>[];
    var buffer = StringBuffer();
    var end = 0;
    for (final match in _word.allMatches(sentence)) {
      buffer.write(sentence.substring(end, match.start));
      end = match.end;
      final entry = lookup(match.group(0)!);
      if (entry == null) { buffer.write(match.group(0)); continue; }
      if (buffer.isNotEmpty) parts.add(SentencePart(buffer.toString()));
      buffer = StringBuffer();
      parts.add(SentencePart(match.group(0)!, entry));
    }
    buffer.write(sentence.substring(end));
    if (buffer.isNotEmpty) parts.add(SentencePart(buffer.toString()));
    return parts;
  }
}
