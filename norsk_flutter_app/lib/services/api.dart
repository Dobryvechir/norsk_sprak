import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/entities.dart';

class Api {
  final Dio dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(minutes: 3)));
  final FlutterSecureStorage secure = const FlutterSecureStorage();
  String baseUrl = '';
  String? token;
  AppUser? user;

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString('server_url') ?? '';
    token = await secure.read(key: 'access_token');
    if (token != null && baseUrl.isNotEmpty) {
      try { user = AppUser.fromJson(Map<String, dynamic>.from((await get('/api/me')).data as Map)); }
      catch (_) { token = null; user = null; await secure.delete(key: 'access_token'); }
    }
  }

  String url(String path) => '${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path';
  Options authOptions({ResponseType? responseType}) => Options(
    headers: {'Authorization': 'Bearer $token'}, responseType: responseType);
  Future<Response<dynamic>> get(String path) => dio.get(url(path), options: authOptions());
  Future<Response<dynamic>> post(String path, {Object? data}) => dio.post(url(path), data: data, options: authOptions());
  Future<Response<dynamic>> patch(String path, Object data) => dio.patch(url(path), data: data, options: authOptions());
  Future<Response<dynamic>> put(String path, Object data) => dio.put(url(path), data: data, options: authOptions());
  Future<Response<dynamic>> delete(String path) => dio.delete(url(path), options: authOptions());

  Future<void> login(String server, String email, String password) async {
    baseUrl = server.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasAuthority || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const FormatException('Enter a valid server URL, including https://');
    }
    final r = await dio.post(url('/api/auth/login'), data: {'email': email.trim(), 'password': password});
    final j = Map<String, dynamic>.from(r.data as Map);
    token = '${j['access_token']}';
    user = AppUser.fromJson(Map<String, dynamic>.from(j['user'] as Map));
    await secure.write(key: 'access_token', value: token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', baseUrl);
  }

  Future<void> logout() async {
    token = null; user = null;
    await secure.delete(key: 'access_token');
  }

  Future<List<StudyGroup>> groups() async => [for (final e in (await get('/api/me/groups')).data as List)
    StudyGroup.fromJson(Map<String, dynamic>.from(e as Map))];
  Future<List<Recording>> recordings(String groupId) async => [for (final e in (await get('/api/groups/$groupId/recordings')).data as List)
    Recording.fromJson(Map<String, dynamic>.from(e as Map))];
  Future<Recording> recording(String id) async => Recording.fromJson(Map<String, dynamic>.from((await get('/api/recordings/$id')).data as Map));
  Future<List<Membership>> members(String groupId) async => [for (final e in (await get('/api/groups/$groupId/members')).data as List)
    Membership.fromJson(Map<String, dynamic>.from(e as Map))];
  Future<void> updateMember(String groupId, Membership member, String role, bool enabled, Map<String, dynamic> quota) async {
    await put('/api/groups/$groupId/members/${member.userId}', {'role': role, 'enabled': enabled, 'quota': quota});
  }
  Future<void> editSentence(String id, int index, String text, int start, int end) async { await patch('/api/recordings/$id/sentences/$index', {'text': text, 'start_ms': start, 'end_ms': end}); }
  Future<void> deleteRecording(String id) async { await delete('/api/recordings/$id'); }
  Future<void> transcribe(String id) async { await post('/api/recordings/$id/transcribe'); }
  Future<AppUser> createUser(String email, String password) async {
    final response = await post('/api/admin/users', data: {'email': email, 'password': password});
    return AppUser.fromJson(Map<String, dynamic>.from(response.data as Map));
  }
  Future<void> createGroup(String name) async { await post('/api/admin/groups', data: {'name': name}); }
  Future<void> addMember(String groupId, String userId, String role) async { await put('/api/groups/$groupId/members/$userId', {'role': role, 'enabled': true, 'quota': <String, dynamic>{}}); }
  Future<void> upload(String groupId, String name, String path, void Function(double) onProgress) async {
    final filename = path.split(Platform.pathSeparator).last;
    final form = FormData.fromMap({'name': name, 'file': await MultipartFile.fromFile(path, filename: filename)});
    await dio.post(url('/api/groups/$groupId/recordings'), data: form, options: authOptions(),
      onSendProgress: (sent, total) { if (total > 0) onProgress(sent / total); });
  }
  /// Downloads the audio to [path] and returns the response headers (used to learn the file type).
  Future<Headers> downloadAudio(String recordingId, String path, void Function(double) onProgress) async {
    final response = await dio.download(url('/api/recordings/$recordingId/audio'), path, options: authOptions(),
      onReceiveProgress: (received, total) { if (total > 0) onProgress(received / total); });
    return response.headers;
  }
}

String readableError(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['detail'] != null) return '${data['detail']}';
    return 'Network error: ${error.message ?? error.type.name}';
  }
  return error.toString();
}
