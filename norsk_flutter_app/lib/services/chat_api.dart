import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import '../models/chat.dart';
import 'api.dart';

/// The /api/chat endpoints. Only text and links go to our server; files stay on Google Drive.
class ChatApi {
  ChatApi(this.api);
  final Api api;

  Map<String, dynamic> _m(Response<dynamic> r) => Map<String, dynamic>.from(r.data as Map);
  List<Map<String, dynamic>> _l(Response<dynamic> r) => [for (final e in r.data as List) Map<String, dynamic>.from(e as Map)];

  /// The group's chat settings (any member may read them; only its admins may change them).
  Future<GroupChatSettings> groupSettings(String groupId) async =>
    GroupChatSettings.fromJson(_m(await api.get('/api/groups/$groupId/settings')));
  Future<GroupChatSettings> saveGroupSettings(String groupId, GroupChatSettings settings) async =>
    GroupChatSettings.fromJson(_m(await api.patch('/api/groups/$groupId/settings', settings.toJson())));

  Future<ChatStatus> status() async => ChatStatus.fromJson(_m(await api.get('/api/chat/status')));
  /// Sets the name shown in Chat and, when [photo] is given, a new photo (PNG or JPEG, at most 64 kB).
  Future<ChatPerson> saveProfile(String displayName, Uint8List? photo) async => ChatPerson.fromJson(_m(await api.put('/api/chat/profile',
    {'displayName': displayName, if (photo != null) 'photo': base64Encode(photo)})));

  /// Photos downloaded so far, by `<user id>:<version>` (kept in memory only).
  static final _photos = <String, Future<Uint8List?>>{};
  /// [person]'s photo, or null when they have none or it can't be loaded.
  Future<Uint8List?> photo(ChatPerson person) {
    if (!person.hasPhoto) return Future.value(null);
    return _photos['${person.id}:${person.photoVersion}'] ??= api.dio.get<List<int>>(api.url('/api/chat/photos/${person.id}'),
        options: api.authOptions(responseType: ResponseType.bytes))
      .then<Uint8List?>((r) => Uint8List.fromList(r.data!)).catchError((Object _) => null);
  }

  Future<List<ChatPerson>> searchUsers(String q) async {
    final r = await api.dio.get(api.url('/api/chat/users'), queryParameters: {'q': q}, options: api.authOptions());
    return [for (final e in _l(r)) ChatPerson.fromJson(e)];
  }

  Future<List<ChatConversation>> conversations() async => [for (final e in _l(await api.get('/api/chat/conversations'))) ChatConversation.fromJson(e)];
  Future<ChatConversation> openDirect(String groupId, String userId) async =>
    ChatConversation.fromJson(_m(await api.post('/api/chat/directs', data: {'groupId': groupId, 'userId': userId})));

  /// Messages, oldest first; with [since] (a message's createdAt) only newer ones.
  Future<List<ChatMessage>> messages(String cid, {String? since}) async {
    final r = await api.dio.get(api.url('/api/chat/conversations/$cid/messages'),
      queryParameters: {if (since != null) 'since': since}, options: api.authOptions());
    return [for (final e in _l(r)) ChatMessage.fromJson(e)];
  }
  Future<ChatMessage> send(String cid, String text, List<ChatAttachment> attachments) async => ChatMessage.fromJson(_m(
    await api.post('/api/chat/conversations/$cid/messages', data: {'text': text, 'attachments': [for (final a in attachments) a.toJson()]})));
  Future<List<ChatPerson>> members(String cid) async => [for (final e in _l(await api.get('/api/chat/conversations/$cid/members'))) ChatPerson.fromJson(e)];

  Future<ChatConversation> createSubgroup(String groupId, String name, bool family) async =>
    ChatConversation.fromJson(_m(await api.post('/api/chat/subgroups', data: {'groupId': groupId, 'name': name, 'family': family})));
  Future<List<ChatInvitation>> invitations() async => [for (final e in _l(await api.get('/api/chat/invitations'))) ChatInvitation.fromJson(e)];
  Future<void> invite(String subgroupId, List<String> userIds) async { await api.post('/api/chat/subgroups/$subgroupId/invite', data: {'userIds': userIds}); }
  Future<ChatConversation> accept(String subgroupId) async => ChatConversation.fromJson(_m(await api.post('/api/chat/subgroups/$subgroupId/accept')));
  Future<void> decline(String subgroupId) async { await api.post('/api/chat/subgroups/$subgroupId/decline'); }
  Future<void> leave(String subgroupId) async { await api.post('/api/chat/subgroups/$subgroupId/leave'); }
  Future<void> removeMember(String subgroupId, String userId) async { await api.delete('/api/chat/subgroups/$subgroupId/members/$userId'); }
  Future<void> deleteSubgroup(String subgroupId) async { await api.delete('/api/chat/subgroups/$subgroupId'); }

  /// "Find location": asks [userId]'s app for its location; returns the last one known.
  Future<ChatLocation?> requestLocation(String cid, String userId) async =>
    ChatLocation.fromJson(_m(await api.post('/api/chat/conversations/$cid/members/$userId/location'))['location']);
  Future<ChatLocation?> location(String cid, String userId) async =>
    ChatLocation.fromJson(_m(await api.get('/api/chat/conversations/$cid/members/$userId/location'))['location']);
  Future<void> sendLocation(double lat, double lng, double? accuracy) async {
    await api.put('/api/chat/location', {'lat': lat, 'lng': lng, if (accuracy != null) 'accuracy': accuracy});
  }
}

/// While the app runs after sign-in, asks the server now and then whether a family member wants this
/// user's location ("Find location"), and if so sends the current one. Nothing is sent otherwise.
class ChatLocationResponder {
  ChatLocationResponder(this.chat);
  final ChatApi chat;
  static const interval = Duration(seconds: 30);
  Timer? _timer;
  bool _busy = false;

  void start() { _timer ??= Timer.periodic(interval, (_) => check()); check(); }
  void stop() { _timer?.cancel(); _timer = null; }

  Future<void> check() async {
    if (_busy || chat.api.token == null || chat.api.offline) return;
    _busy = true;
    try {
      if (!(await chat.status()).locationRequested) return;
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return;
      final p = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(timeLimit: Duration(seconds: 20)));
      await chat.sendLocation(p.latitude, p.longitude, p.accuracy);
    } catch (_) {
      // No connection, no permission, no fix: try again at the next check.
    } finally { _busy = false; }
  }
}
