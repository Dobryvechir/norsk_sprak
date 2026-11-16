class AppUser {
  final String id, email;
  final bool systemAdmin;
  const AppUser(this.id, this.email, this.systemAdmin);
  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser('${j['id']}', '${j['email']}', j['system_admin'] == true);
  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'system_admin': systemAdmin};
}

class StudyGroup {
  final String id, name;
  /// The logged-in user's role in this group (viewer/uploader/admin), when the server reports it.
  final String? myRole;
  /// The group's privilege level: 0 = "Basic" (its members may change to the Pro plan), 1 = "Advanced".
  final int? privilege;
  /// How many recordings with their own texts each member may share per month (0 = none), when reported.
  final int? shareRecords;
  const StudyGroup(this.id, this.name, [this.myRole, this.privilege, this.shareRecords]);
  bool get isAdmin => myRole == 'admin';
  bool get isBasic => privilege == 0;
  /// Whether the user's role allows AI transcription at all (the server still checks the group's quotas).
  bool get mayUseAi => myRole == 'uploader' || myRole == 'admin';
  factory StudyGroup.fromJson(Map<String, dynamic> j) =>
    StudyGroup('${j['id']}', '${j['name']}', j['my_role'] as String?, (j['privilege'] as num?)?.toInt(),
      (j['shareRecords'] as num?)?.toInt());
}

/// A person who signed up and waits for a system admin (never includes the password).
class SignupCandidate {
  final String id, email, info, ip, browser, status;
  final DateTime? createdAt;
  /// The created user's id, once approved.
  final String? userId;
  /// Whether the person opened the link in the verification email.
  final bool emailVerified;
  /// "basic", "pro" or null (no plan chosen yet).
  final String? plan;
  /// Pro payment: "processing", "paid", "failed" or null; and how ("vipps", "googlepay", "applepay").
  final String? paymentStatus, paymentMethod;
  /// The group the approval dialog suggests (the "Basic" group for people who did not pay).
  final String? defaultGroupId;
  const SignupCandidate(this.id, this.email, this.info, this.ip, this.browser, this.status, this.createdAt, this.userId,
      {this.emailVerified = false, this.plan, this.paymentStatus, this.paymentMethod, this.defaultGroupId});
  bool get isPending => status == 'pending';
  factory SignupCandidate.fromJson(Map<String, dynamic> j) {
    final payment = j['payment'] is Map ? j['payment'] as Map : const {};
    return SignupCandidate('${j['id']}', '${j['email']}',
      '${j['info'] ?? ''}', '${j['ip'] ?? ''}', '${j['browser'] ?? ''}', '${j['status']}',
      DateTime.tryParse('${j['created_at']}')?.toLocal(), j['user_id'] as String?,
      emailVerified: j['email_verified'] == true, plan: j['plan'] as String?,
      paymentStatus: payment['status'] as String?, paymentMethod: payment['method'] as String?,
      defaultGroupId: j['default_group_id'] as String?);
  }
}

enum NotificationLevel { info, warning, critical, fatal }

/// A message from the system admin (see the server's routes/notifications.py).
class AppNotification {
  final String id, text;
  final int severity;
  final String? versionFrom, versionTo, groupId, userId;
  final int? privilegeFrom, privilegeTo;
  final DateTime? datetimeFrom, datetimeTo, createdAt;
  const AppNotification(this.id, this.text, this.severity, {this.versionFrom, this.versionTo, this.groupId, this.userId,
      this.privilegeFrom, this.privilegeTo, this.datetimeFrom, this.datetimeTo, this.createdAt});
  /// <=10 info, 11-20 warning, 21-30 critical, >=31 fatal (the app shows only it and stops).
  NotificationLevel get level => severity <= 10 ? NotificationLevel.info : severity <= 20 ? NotificationLevel.warning
    : severity <= 30 ? NotificationLevel.critical : NotificationLevel.fatal;
  bool get isFatal => level == NotificationLevel.fatal;
  /// Last digit 0: shown every time.
  bool get showAlways => !isFatal && severity % 10 == 0;
  /// Last digit 1: shown only once.
  bool get showOnce => !isFatal && severity % 10 == 1;
  /// Any other last digit: shown until the user chooses "Do not remind again".
  bool get dismissible => !isFatal && !showAlways && !showOnce;
  static DateTime? _date(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
  static int? _int(Object? v) => (v as num?)?.toInt();
  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification('${j['id']}', '${j['text'] ?? ''}', _int(j['severity']) ?? 0,
    versionFrom: j['versionFrom'] as String?, versionTo: j['versionTo'] as String?,
    groupId: j['groupId'] as String?, userId: j['userId'] as String?,
    privilegeFrom: _int(j['privilegeFrom']), privilegeTo: _int(j['privilegeTo']),
    datetimeFrom: _date(j['datetimeFrom']), datetimeTo: _date(j['datetimeTo']), createdAt: _date(j['created_at']));
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
  /// For a chapter saved on this device: the name of the downloaded audio file (see OfflineChapters).
  final String? localFile;
  /// Where the audio file is, when it is not in the server's own storage (e.g. book chapters).
  /// If set, the audio is fetched from here instead of the server's audio endpoint.
  final String? url;
  const RecordingAudio(this.status, this.createdAt, this.durationSeconds, this.error, this.startMs, this.endMs, [this.localFile, this.url]);
  bool get isTranscribing => status == 'pending' || status == 'processing';
  factory RecordingAudio.fromJson(Map<String, dynamic> j) {
    List<int> ints(Object? v) => [for (final x in (v as List?) ?? const []) (x as num).toInt()];
    final url = j['url'] as String?;
    return RecordingAudio('${j['status']}', '${j['created_at'] ?? ''}', (j['duration_seconds'] as num?)?.toDouble() ?? 0,
      j['error']?.toString(), ints(j['start_ms']), ints(j['end_ms']), j['local_file'] as String?,
      url == null || url.isEmpty ? null : url);
  }
  Map<String, dynamic> toJson() => {'status': status, 'created_at': createdAt, 'duration_seconds': durationSeconds,
    if (error != null) 'error': error, 'start_ms': startMs, 'end_ms': endMs, if (localFile != null) 'local_file': localFile,
    if (url != null) 'url': url};
  RecordingAudio withLocalFile(String file) => RecordingAudio(status, createdAt, durationSeconds, error, startMs, endMs, file, url);
}

/// Who made a recording, when, and its approximate size: shown in the lists of shared and saved recordings.
class RecordingInfo {
  final String? uploaderId, author, createdAt;
  /// The media files plus the texts, in bytes (on the server an estimate; for a saved copy what it takes here).
  final int? sizeBytes;
  /// "file" (shared with the user's own texts), "ai" (transcribed by the server) or "local" (made on this
  /// device and not shared).
  final String? source;
  const RecordingInfo({this.uploaderId, this.author, this.createdAt, this.sizeBytes, this.source});
  DateTime? get created => createdAt == null ? null : DateTime.tryParse(createdAt!)?.toLocal();
  RecordingInfo withSize(int bytes) => RecordingInfo(uploaderId: uploaderId, author: author, createdAt: createdAt, sizeBytes: bytes, source: source);
}

/// A recording: per language an optional audio, and per language optional sentence texts.
/// Sentence i means the same sentence in every language.
/// A book chapter has the same shape, with [sectionId] instead of a group ([groupId] is then '').
class Recording {
  final String id, groupId, name;
  final String? sectionId;
  final Map<String, RecordingAudio> audio;
  final Map<String, List<String>> sentences;
  final RecordingInfo info;
  const Recording(this.id, this.groupId, this.name, this.audio, this.sentences, [this.sectionId, this.info = const RecordingInfo()]);
  bool get isChapter => sectionId != null;
  /// Whether every audio has its texts and timings (none queued for AI or failed).
  bool get isReady => audio.values.every((a) => a.status == 'ready');
  factory Recording.fromJson(Map<String, dynamic> j) => Recording('${j['id']}', '${j['group_id'] ?? ''}', '${j['name']}',
    {for (final e in ((j['audio'] as Map?) ?? const {}).entries) '${e.key}': RecordingAudio.fromJson(Map<String, dynamic>.from(e.value as Map))},
    {for (final e in ((j['sentences'] as Map?) ?? const {}).entries) '${e.key}': [for (final t in e.value as List) '$t']},
    j['sectionId'] as String?,
    RecordingInfo(uploaderId: j['uploader_id'] as String?, author: j['author'] as String?, createdAt: j['created_at'] as String?,
      sizeBytes: (j['size_bytes'] as num?)?.toInt(), source: j['source'] as String?));
  /// The same JSON as [Recording.fromJson] reads.
  Map<String, dynamic> toJson() => {'id': id, 'group_id': groupId, 'name': name, if (sectionId != null) 'sectionId': sectionId,
    'audio': {for (final e in audio.entries) e.key: e.value.toJson()}, 'sentences': sentences,
    if (info.uploaderId != null) 'uploader_id': info.uploaderId, if (info.author != null) 'author': info.author,
    if (info.createdAt != null) 'created_at': info.createdAt, if (info.sizeBytes != null) 'size_bytes': info.sizeBytes,
    if (info.source != null) 'source': info.source};
  Recording withAudio(Map<String, RecordingAudio> audio) => Recording(id, groupId, name, audio, sentences, sectionId, info);
  Recording withInfo(RecordingInfo info) => Recording(id, groupId, name, audio, sentences, sectionId, info);

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

/// An audio or video file the user saved through Media on their own Google Drive, used as a
/// recording's audio. [kind] is "audio" or "video".
class RecordingMedia {
  final String driveId, name, kind;
  final String? mimeType;
  /// In bytes, when Drive reports it.
  final int? size;
  const RecordingMedia(this.driveId, this.name, this.kind, [this.mimeType, this.size]);
}

/// How many recordings with their own texts the user may still share in a group this month
/// ([limit] and [remaining] are null when unlimited).
class ShareAllowance {
  final bool enabled;
  final int? limit, remaining;
  final int used;
  const ShareAllowance(this.enabled, {this.limit, this.remaining, this.used = 0});
  factory ShareAllowance.fromJson(Map<String, dynamic> j) => ShareAllowance(j['enabled'] == true,
    limit: (j['limit'] as num?)?.toInt(), remaining: (j['remaining'] as num?)?.toInt(), used: (j['used'] as num?)?.toInt() ?? 0);
}

/// Whether the user may have a recording transcribed by AI in a group now ([reason] says why not:
/// "disabled", "recordings", "minutes" or "group_minutes"), and what is left this month (null = no limit).
class AiAllowance {
  final bool enabled;
  final String? reason;
  final int? remainingRecordings, maxDurationMinutes;
  final double? remainingMinutes;
  const AiAllowance(this.enabled, {this.reason, this.remainingRecordings, this.remainingMinutes, this.maxDurationMinutes});
  factory AiAllowance.fromJson(Map<String, dynamic> j) => AiAllowance(j['enabled'] == true, reason: j['reason'] as String?,
    remainingRecordings: (j['remaining_recordings'] as num?)?.toInt(), remainingMinutes: (j['remaining_minutes'] as num?)?.toDouble(),
    maxDurationMinutes: (j['max_duration_minutes'] as num?)?.toInt());
}
