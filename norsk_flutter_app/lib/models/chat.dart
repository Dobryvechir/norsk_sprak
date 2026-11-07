/// Chat entities, as sent by the server's /api/chat endpoints (see the backend's docs/chat.md).
library;

Map<String, dynamic> _map(Object? v) => Map<String, dynamic>.from((v as Map?) ?? const {});

/// Someone as shown in Chat: a name and, when [hasPhoto], a photo (changed whenever [photoVersion] changes).
class ChatPerson {
  final String id, displayName;
  final bool hasPhoto, owner, invited;
  final int photoVersion;
  /// For search results: the non-anonymous groups shared with this person, as (id, name).
  final List<(String, String)> groups;
  const ChatPerson(this.id, this.displayName, {this.hasPhoto = false, this.photoVersion = 0, this.owner = false,
    this.invited = false, this.groups = const []});
  factory ChatPerson.fromJson(Map<String, dynamic> j) => ChatPerson('${j['id']}', '${j['displayName'] ?? ''}',
    hasPhoto: j['hasPhoto'] == true, photoVersion: (j['photoVersion'] as num?)?.toInt() ?? 0,
    owner: j['owner'] == true, invited: j['invited'] == true,
    groups: [for (final g in (j['groups'] as List?) ?? const []) ('${(g as Map)['id']}', '${g['name']}')]);
}

/// The signed-in user's own chat state.
class ChatStatus extends ChatPerson {
  final int invitations;
  final bool locationRequested;
  const ChatStatus(super.id, super.displayName, {super.hasPhoto, super.photoVersion, this.invitations = 0, this.locationRequested = false});
  factory ChatStatus.fromJson(Map<String, dynamic> j) {
    final p = ChatPerson.fromJson(j);
    return ChatStatus(p.id, p.displayName, hasPhoto: p.hasPhoto, photoVersion: p.photoVersion,
      invitations: (j['invitations'] as num?)?.toInt() ?? 0, locationRequested: j['locationRequested'] == true);
  }
}

/// A chat: a whole group, a subgroup or two people.
class ChatConversation {
  final String id, type, name, groupId, groupName;
  final bool family, isOwner;
  final String? lastAt, otherUserId;
  const ChatConversation(this.id, this.type, this.name, this.groupId, this.groupName,
    {this.family = false, this.isOwner = false, this.lastAt, this.otherUserId});
  bool get isGroup => type == 'group';
  bool get isSubgroup => type == 'subgroup';
  bool get isDirect => type == 'direct';
  /// The subgroup's id (without the `s-` prefix of the conversation id).
  String get subgroupId => id.substring(2);
  factory ChatConversation.fromJson(Map<String, dynamic> j) => ChatConversation('${j['id']}', '${j['type']}', '${j['name']}',
    '${j['groupId']}', '${j['groupName'] ?? ''}', family: j['family'] == true, isOwner: j['isOwner'] == true,
    lastAt: j['lastAt'] as String?, otherUserId: j['otherUserId'] as String?);
}

/// What can be attached to a message: always a link to a file on the sender's Google Drive.
enum AttachmentKind { picture, audio, video, file }

class ChatAttachment {
  final AttachmentKind kind;
  final String name, url, driveId, mimeType;
  final int? size;
  const ChatAttachment(this.kind, this.name, this.url, {this.driveId = '', this.mimeType = '', this.size});
  factory ChatAttachment.fromJson(Map<String, dynamic> j) => ChatAttachment(
    AttachmentKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => AttachmentKind.file),
    '${j['name']}', '${j['url']}', driveId: '${j['driveId'] ?? ''}', mimeType: '${j['mimeType'] ?? ''}',
    size: (j['size'] as num?)?.toInt());
  Map<String, dynamic> toJson() => {'kind': kind.name, 'name': name, 'url': url,
    if (driveId.isNotEmpty) 'driveId': driveId, if (mimeType.isNotEmpty) 'mimeType': mimeType, if (size != null) 'size': size};
  /// A small preview of a picture shared "anyone with the link" (no sign-in needed).
  String? get thumbnailUrl => driveId.isEmpty ? null : 'https://drive.google.com/thumbnail?id=$driveId&sz=w480';
}

class ChatMessage {
  final String id, senderId, createdAt, text;
  final List<ChatAttachment> attachments;
  const ChatMessage(this.id, this.senderId, this.createdAt, this.text, this.attachments);
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage('${j['id']}', '${j['senderId']}', '${j['createdAt']}',
    '${j['text'] ?? ''}', [for (final a in (j['attachments'] as List?) ?? const []) ChatAttachment.fromJson(_map(a))]);
  DateTime get time => DateTime.tryParse(createdAt)?.toLocal() ?? DateTime.now();
}

/// An invitation to join a subgroup.
class ChatInvitation {
  final String id, name, groupName;
  final bool family;
  final ChatPerson invitedBy;
  const ChatInvitation(this.id, this.name, this.groupName, this.family, this.invitedBy);
  factory ChatInvitation.fromJson(Map<String, dynamic> j) => ChatInvitation('${j['id']}', '${j['name']}', '${j['groupName']}',
    j['family'] == true, ChatPerson.fromJson(_map(j['invitedBy'])));
}

/// A family member's last known location.
class ChatLocation {
  final double lat, lng;
  final double? accuracy;
  final DateTime updatedAt;
  const ChatLocation(this.lat, this.lng, this.accuracy, this.updatedAt);
  static ChatLocation? fromJson(Object? v) {
    if (v is! Map) return null;
    return ChatLocation((v['lat'] as num).toDouble(), (v['lng'] as num).toDouble(), (v['accuracy'] as num?)?.toDouble(),
      DateTime.tryParse('${v['updatedAt']}')?.toLocal() ?? DateTime.now());
  }
  Uri get mapsUrl => Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
}

/// A group's chat settings (set by its admin; see the backend's docs/chat.md).
class GroupChatSettings {
  final bool anonymous, family;
  final int subgroupLimitPerYear, chatPerDayKb, expirationDays;
  const GroupChatSettings({this.anonymous = false, this.family = false, this.subgroupLimitPerYear = 20,
    this.chatPerDayKb = 500, this.expirationDays = 7});
  factory GroupChatSettings.fromJson(Map<String, dynamic> j) => GroupChatSettings(anonymous: j['anonymous'] == true,
    family: j['family'] == true, subgroupLimitPerYear: (j['subgroupLimitPerYear'] as num?)?.toInt() ?? 20,
    chatPerDayKb: (j['chatPerDayKb'] as num?)?.toInt() ?? 500, expirationDays: (j['expirationDays'] as num?)?.toInt() ?? 7);
  Map<String, dynamic> toJson() => {'anonymous': anonymous, 'family': family, 'subgroupLimitPerYear': subgroupLimitPerYear,
    'chatPerDayKb': chatPerDayKb, 'expirationDays': expirationDays};
}
