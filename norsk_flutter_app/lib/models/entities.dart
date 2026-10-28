class AppUser {
  final String id, email;
  final bool systemAdmin;
  const AppUser(this.id, this.email, this.systemAdmin);
  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser('${j['id']}', '${j['email']}', j['system_admin'] == true);
}

class StudyGroup {
  final String id, name;
  /// The logged-in user's role in this group (viewer/uploader/admin), when the server reports it.
  final String? myRole;
  const StudyGroup(this.id, this.name, [this.myRole]);
  bool get isAdmin => myRole == 'admin';
  factory StudyGroup.fromJson(Map<String, dynamic> j) => StudyGroup('${j['id']}', '${j['name']}', j['my_role'] as String?);
}

/// One sentence of one language's audio, with its timing in that audio (what SentencePlayer plays).
class Sentence {
  final int index, startMs, endMs;
  final String text;
  const Sentence(this.index, this.startMs, this.endMs, this.text);
}

/// A recording's audio in one language.
class RecordingAudio {
  final String status, createdAt;
  final double durationSeconds;
  final String? error;
  /// Timing of sentence i in this audio.
  final List<int> startMs, endMs;
  const RecordingAudio(this.status, this.createdAt, this.durationSeconds, this.error, this.startMs, this.endMs);
  bool get isTranscribing => status == 'pending' || status == 'processing';
  factory RecordingAudio.fromJson(Map<String, dynamic> j) {
    List<int> ints(Object? v) => [for (final x in (v as List?) ?? const []) (x as num).toInt()];
    return RecordingAudio('${j['status']}', '${j['created_at'] ?? ''}', (j['duration_seconds'] as num?)?.toDouble() ?? 0,
      j['error']?.toString(), ints(j['start_ms']), ints(j['end_ms']));
  }
}

/// A recording: per language an optional audio, and per language optional sentence texts.
/// Sentence i means the same sentence in every language.
/// A book chapter has the same shape, with [sectionId] instead of a group ([groupId] is then '').
class Recording {
  final String id, groupId, name;
  final String? sectionId;
  final Map<String, RecordingAudio> audio;
  final Map<String, List<String>> sentences;
  const Recording(this.id, this.groupId, this.name, this.audio, this.sentences, [this.sectionId]);
  bool get isChapter => sectionId != null;
  factory Recording.fromJson(Map<String, dynamic> j) => Recording('${j['id']}', '${j['group_id'] ?? ''}', '${j['name']}',
    {for (final e in ((j['audio'] as Map?) ?? const {}).entries) '${e.key}': RecordingAudio.fromJson(Map<String, dynamic>.from(e.value as Map))},
    {for (final e in ((j['sentences'] as Map?) ?? const {}).entries) '${e.key}': [for (final t in e.value as List) '$t']},
    j['sectionId'] as String?);

  /// Number of sentences: the longest sentence or timing list of any language.
  int get sentenceCount => [
    for (final s in sentences.values) s.length,
    for (final a in audio.values) a.startMs.length,
  ].fold(0, (a, b) => a > b ? a : b);

  /// Text of sentence [index] in [language], or '' if there is none.
  String text(String language, int index) {
    final list = sentences[language];
    return list != null && index < list.length ? list[index] : '';
  }

  /// The sentences of [language]'s audio with their timings, ready to play.
  List<Sentence> timedSentences(String language) {
    final a = audio[language];
    if (a == null) return const [];
    return [for (var i = 0; i < a.startMs.length && i < a.endMs.length; i++) Sentence(i, a.startMs[i], a.endMs[i], text(language, i))];
  }
}

/// A read-only book. [names] maps language codes to the book's name; not every language is present.
class Book {
  final String id, author, icon;
  final Map<String, String> names;
  final List<String> audioLanguages, groups;
  const Book(this.id, this.names, this.author, this.audioLanguages, this.groups, this.icon);
  factory Book.fromJson(Map<String, dynamic> j) => Book('${j['id']}',
    {for (final e in ((j['name'] as Map?) ?? const {}).entries) if ('${e.value}'.isNotEmpty) '${e.key}': '${e.value}'},
    '${j['author'] ?? ''}', [for (final l in (j['audioLanguages'] as List?) ?? const []) '$l'],
    [for (final g in (j['groups'] as List?) ?? const []) '$g'], '${j['icon'] ?? ''}');
  /// The name in [language], else in English, else the first one available.
  String displayName(String language) => names[language] ?? names['en'] ?? (names.isEmpty ? '' : names.values.first);
}

/// A part of a book: the same fields as a book, plus the book it belongs to.
class Section extends Book {
  final String bookId;
  const Section(super.id, super.names, super.author, super.audioLanguages, super.groups, super.icon, this.bookId);
  factory Section.fromJson(Map<String, dynamic> j) {
    final b = Book.fromJson(j);
    return Section(b.id, b.names, b.author, b.audioLanguages, b.groups, b.icon, '${j['bookId']}');
  }
}

/// One page of a paged list from the server.
class PagedList<T> {
  final List<T> items;
  final int total, page, pageSize;
  const PagedList(this.items, this.total, this.page, this.pageSize);
  int get pages => (total + pageSize - 1) ~/ pageSize;
  factory PagedList.fromJson(Map<String, dynamic> j, T Function(Map<String, dynamic>) item) => PagedList(
    [for (final e in j['items'] as List) item(Map<String, dynamic>.from(e as Map))],
    (j['total'] as num).toInt(), (j['page'] as num).toInt(), (j['page_size'] as num).toInt());
}

class Membership {
  final String userId, groupId, role;
  final bool enabled;
  final Map<String, dynamic> quota;
  const Membership(this.userId, this.groupId, this.role, this.enabled, this.quota);
  factory Membership.fromJson(Map<String, dynamic> j) => Membership('${j['user_id']}', '${j['group_id']}',
    '${j['role']}', j['enabled'] != false, Map<String, dynamic>.from((j['quota'] as Map?) ?? {}));
}
