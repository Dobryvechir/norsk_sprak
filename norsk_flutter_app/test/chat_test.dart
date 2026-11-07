import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/models/chat.dart';
import 'package:norsk_audio_groups/services/google_drive.dart';
import 'package:norsk_audio_groups/services/settings.dart';

/// Answers the two calls of [GoogleDrive.shareWithAnyone] and records them.
class _ShareAdapter implements HttpClientAdapter {
  final calls = <String>[];
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    calls.add('${o.method} ${o.uri.path} ${o.data is Map ? jsonEncode(o.data) : ''}'.trim());
    final reply = o.method == 'POST' ? {'id': 'perm'} : {'webViewLink': 'https://drive.google.com/file/d/f1/view'};
    return ResponseBody.fromString(jsonEncode(reply), 200, headers: {'content-type': ['application/json']});
  }
  @override void close({bool force = false}) {}
}

void main() {
  test('messages, attachments and conversations are read from the server JSON', () {
    final m = ChatMessage.fromJson({'id': '1', 'senderId': 'u', 'createdAt': '2026-11-07T10:00:00.000000+00:00', 'text': 'hi',
      'attachments': [{'kind': 'picture', 'name': 'a.jpg', 'url': 'https://drive.google.com/file/d/f1/view', 'driveId': 'f1'}]});
    expect(m.attachments.single.kind, AttachmentKind.picture);
    expect(m.attachments.single.thumbnailUrl, contains('id=f1'));
    expect(ChatAttachment.fromJson(m.attachments.single.toJson()).url, m.attachments.single.url);

    final c = ChatConversation.fromJson({'id': 's-abc', 'type': 'subgroup', 'name': 'Us', 'groupId': 'g', 'groupName': 'G',
      'family': true, 'isOwner': true});
    expect((c.isSubgroup, c.subgroupId, c.family), (true, 'abc', true));

    final status = ChatStatus.fromJson({'id': 'u', 'displayName': 'Ann', 'hasPhoto': true, 'photoVersion': 2,
      'invitations': 1, 'locationRequested': true});
    expect((status.hasPhoto, status.photoVersion, status.locationRequested), (true, 2, true));
  });

  test('group chat settings: defaults for missing fields, and sent back unchanged', () {
    final d = GroupChatSettings.fromJson({});
    expect((d.anonymous, d.family, d.subgroupLimitPerYear, d.chatPerDayKb, d.expirationDays), (false, false, 20, 500, 7));
    final json = {'anonymous': true, 'family': true, 'subgroupLimitPerYear': 3, 'chatPerDayKb': 50, 'expirationDays': 2};
    expect(GroupChatSettings.fromJson(json).toJson(), json);
  });

  test('a location opens in Google Maps', () {
    final l = ChatLocation.fromJson({'lat': 59.91, 'lng': 10.75, 'accuracy': 12, 'updatedAt': '2026-11-07T10:00:00+00:00'})!;
    expect(l.mapsUrl.toString(), 'https://www.google.com/maps/search/?api=1&query=59.91,10.75');
    expect(ChatLocation.fromJson(null), isNull);
  });

  test('sharing a Drive file makes it readable by anyone with the link', () async {
    AppSettings.instance.googleDriveToken = 'good';
    final adapter = _ShareAdapter();
    final link = await GoogleDrive(dio: Dio()..httpClientAdapter = adapter).shareWithAnyone('f1');
    expect(link, 'https://drive.google.com/file/d/f1/view');
    expect(adapter.calls.first, 'POST /drive/v3/files/f1/permissions {"role":"reader","type":"anyone"}');
  });
}
