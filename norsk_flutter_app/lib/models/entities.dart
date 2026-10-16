class AppUser {
  final String id, email;
  final bool systemAdmin;
  const AppUser(this.id, this.email, this.systemAdmin);
  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser('${j['id']}', '${j['email']}', j['system_admin'] == true);
}

class StudyGroup {
  final String id, name;
  const StudyGroup(this.id, this.name);
  factory StudyGroup.fromJson(Map<String, dynamic> j) => StudyGroup('${j['id']}', '${j['name']}');
}

class Sentence {
  final int index, startMs, endMs;
  final String text;
  const Sentence(this.index, this.startMs, this.endMs, this.text);
  factory Sentence.fromJson(Map<String, dynamic> j, int i) => Sentence(
    (j['index'] as num?)?.toInt() ?? i,
    (j['start_ms'] as num?)?.toInt() ?? 0,
    (j['end_ms'] as num?)?.toInt() ?? 0,
    '${j['text'] ?? ''}',
  );
}

class Recording {
  final String id, groupId, name, status;
  final double durationSeconds;
  final String? error;
  final List<Sentence> sentences;
  const Recording(this.id, this.groupId, this.name, this.status, this.durationSeconds, this.error, this.sentences);
  factory Recording.fromJson(Map<String, dynamic> j) {
    final raw = (j['sentences'] as List?) ?? [];
    return Recording('${j['id']}', '${j['group_id']}', '${j['name']}', '${j['status']}',
      (j['duration_seconds'] as num?)?.toDouble() ?? 0, j['error']?.toString(),
      [for (var i = 0; i < raw.length; i++) Sentence.fromJson(Map<String, dynamic>.from(raw[i] as Map), i)]);
  }
}

class Membership {
  final String userId, groupId, role;
  final bool enabled;
  final Map<String, dynamic> quota;
  const Membership(this.userId, this.groupId, this.role, this.enabled, this.quota);
  factory Membership.fromJson(Map<String, dynamic> j) => Membership('${j['user_id']}', '${j['group_id']}',
    '${j['role']}', j['enabled'] != false, Map<String, dynamic>.from((j['quota'] as Map?) ?? {}));
}
