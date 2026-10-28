import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';

class Api {
  final Dio dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(minutes: 3)));
  final FlutterSecureStorage secure = const FlutterSecureStorage();
  String baseUrl = '';
  String? token;
  AppUser? user;

  String rememberedEmail = '';
  bool rememberName = false, keepLoggedIn = false;
  /// Groups fetched while restoring a saved session, handed to the first MenuScreen.
  List<StudyGroup>? restoredGroups;
  /// Why a saved session could not be restored (shown on the login page).
  Object? restoreError;

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString('server_url') ?? '';
    rememberName = prefs.getBool('remember_name') ?? false;
    keepLoggedIn = prefs.getBool('keep_logged_in') ?? false;
    rememberedEmail = rememberName ? prefs.getString('remembered_email') ?? '' : '';
    token = await secure.read(key: 'access_token');
    if (token == null) return;
    if (baseUrl.isEmpty || tokenExpired(token!)) { await _forgetToken(); return; }
    try {
      final results = await Future.wait([get('/api/me/groups'), get('/api/me')]);
      restoredGroups = [for (final e in results[0].data as List) StudyGroup.fromJson(Map<String, dynamic>.from(e as Map))];
      user = AppUser.fromJson(Map<String, dynamic>.from(results[1].data as Map));
    } catch (e) {
      user = null; restoredGroups = null;
      if (e is DioException && (e.response?.statusCode == 401 || e.response?.statusCode == 403)) { await _forgetToken(); }
      else { token = null; restoreError = e; }
    }
  }

  Future<void> _forgetToken() async { token = null; user = null; await secure.delete(key: 'access_token'); }

  /// True when the JWT's `exp` claim is in the past (or the token can't be read).
  static bool tokenExpired(String jwt) {
    try {
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(jwt.split('.')[1])))) as Map;
      final exp = payload['exp'];
      if (exp is! num) return false;
      return DateTime.now().isAfter(DateTime.fromMillisecondsSinceEpoch((exp * 1000).toInt()));
    } catch (_) { return true; }
  }

  String url(String path) => '${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path';
  /// An absolute URL as is; a relative one (e.g. `/static/x.png`) resolved against the server.
  String resolveUrl(String link) => Uri.parse('$baseUrl/').resolve(link).toString();
  Options authOptions({ResponseType? responseType}) => Options(
    headers: {'Authorization': 'Bearer $token'}, responseType: responseType);
  Future<Response<dynamic>> get(String path) => dio.get(url(path), options: authOptions());
  Future<Response<dynamic>> post(String path, {Object? data}) => dio.post(url(path), data: data, options: authOptions());
  Future<Response<dynamic>> patch(String path, Object data) => dio.patch(url(path), data: data, options: authOptions());
  Future<Response<dynamic>> put(String path, Object data) => dio.put(url(path), data: data, options: authOptions());
  Future<Response<dynamic>> delete(String path) => dio.delete(url(path), options: authOptions());

  Future<void> login(String server, String email, String password, {required bool rememberName, required bool keepLoggedIn}) async {
    baseUrl = server.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasAuthority || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw FormatException(trNow('invalidServerUrl'));
    }
    final r = await dio.post(url('/api/auth/login'), data: {'email': email.trim(), 'password': password});
    final j = Map<String, dynamic>.from(r.data as Map);
    token = '${j['access_token']}';
    user = AppUser.fromJson(Map<String, dynamic>.from(j['user'] as Map));
    this.rememberName = rememberName; this.keepLoggedIn = keepLoggedIn;
    rememberedEmail = rememberName ? email.trim() : '';
    restoreError = null;
    if (keepLoggedIn) { await secure.write(key: 'access_token', value: token); }
    else { await secure.delete(key: 'access_token'); }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', baseUrl);
    await prefs.setBool('remember_name', rememberName);
    await prefs.setBool('keep_logged_in', keepLoggedIn);
    if (rememberName) { await prefs.setString('remembered_email', rememberedEmail); }
    else { await prefs.remove('remembered_email'); }
  }

  Future<void> logout() async {
    restoredGroups = null;
    await _forgetToken();
  }

  /// Whether the user may see the Admin menu: system admins and admins of at least one group.
  bool hasAdminRights(List<StudyGroup> groups) => user?.systemAdmin == true || groups.any((g) => g.isAdmin);

  Future<List<StudyGroup>> groups() async => [for (final e in (await get('/api/me/groups')).data as List)
    StudyGroup.fromJson(Map<String, dynamic>.from(e as Map))];
  Future<PagedList<T>> _paged<T>(String path, Map<String, dynamic> query, T Function(Map<String, dynamic>) item) async {
    final r = await dio.get(url(path), options: authOptions(), queryParameters: query);
    return PagedList.fromJson(Map<String, dynamic>.from(r.data as Map), item);
  }
  /// Books the user may see whose name (in any language) contains [query], sorted by name in [language].
  Future<PagedList<Book>> books(String query, int page, int pageSize, String language) =>
    _paged('/api/books', {'q': query, 'page': page, 'page_size': pageSize, 'lang': language}, Book.fromJson);
  /// The book's sections the user may see, searched and sorted like [books].
  Future<PagedList<Section>> sections(String bookId, String query, int page, int pageSize, String language) =>
    _paged('/api/books/$bookId/sections', {'q': query, 'page': page, 'page_size': pageSize, 'lang': language}, Section.fromJson);
  Future<PagedList<Recording>> chapters(String sectionId, int page, int pageSize) =>
    _paged('/api/sections/$sectionId/chapters', {'page': page, 'page_size': pageSize}, Recording.fromJson);
  Future<Recording> chapter(String id) async => Recording.fromJson(Map<String, dynamic>.from((await get('/api/chapters/$id')).data as Map));
  Future<List<Recording>> recordings(String groupId) async => [for (final e in (await get('/api/groups/$groupId/recordings')).data as List)
    Recording.fromJson(Map<String, dynamic>.from(e as Map))];
  Future<Recording> recording(String id) async => Recording.fromJson(Map<String, dynamic>.from((await get('/api/recordings/$id')).data as Map));
  Future<List<Membership>> members(String groupId) async => [for (final e in (await get('/api/groups/$groupId/members')).data as List)
    Membership.fromJson(Map<String, dynamic>.from(e as Map))];
  Future<void> updateMember(String groupId, Membership member, String role, bool enabled, Map<String, dynamic> quota) async {
    await put('/api/groups/$groupId/members/${member.userId}', {'role': role, 'enabled': enabled, 'quota': quota});
  }
  /// Changes sentence [index] in [language]: its text, its timing in that language's audio, or both.
  Future<void> editSentence(String id, String language, int index, {String? text, int? start, int? end}) async {
    await patch('/api/recordings/$id/sentences/$language/$index', {if (text != null) 'text': text, if (start != null) 'start_ms': start, if (end != null) 'end_ms': end});
  }
  Future<void> deleteRecording(String id) async { await delete('/api/recordings/$id'); }
  Future<void> transcribe(String id, String language) async { await post('/api/recordings/$id/transcribe/$language'); }
  Future<AppUser> createUser(String email, String password) async {
    final response = await post('/api/admin/users', data: {'email': email, 'password': password});
    return AppUser.fromJson(Map<String, dynamic>.from(response.data as Map));
  }
  Future<void> createGroup(String name) async { await post('/api/admin/groups', data: {'name': name}); }
  Future<void> addMember(String groupId, String userId, String role) async { await put('/api/groups/$groupId/members/$userId', {'role': role, 'enabled': true, 'quota': <String, dynamic>{}}); }
  /// Creates a recording in [groupId] from an audio file spoken in [language].
  Future<void> upload(String groupId, String name, String language, String path, void Function(double) onProgress) =>
    _sendAudio('post', '/api/groups/$groupId/recordings', {'name': name, 'language': language}, path, onProgress);
  /// Adds the audio in [language] to an existing recording, or replaces it.
  Future<void> uploadAudio(String recordingId, String language, String path, void Function(double) onProgress) =>
    _sendAudio('put', '/api/recordings/$recordingId/audio/$language', {}, path, onProgress);
  Future<void> _sendAudio(String method, String path, Map<String, dynamic> fields, String filePath, void Function(double) onProgress) async {
    final filename = filePath.split(Platform.pathSeparator).last;
    final form = FormData.fromMap({...fields, 'file': await MultipartFile.fromFile(filePath, filename: filename)});
    await dio.request(url(path), data: form, options: authOptions().copyWith(method: method.toUpperCase()),
      onSendProgress: (sent, total) { if (total > 0) onProgress(sent / total); });
  }
  /// Downloads the audio to [path] and returns the response headers (used to learn the file type).
  Future<Headers> downloadAudio(Recording r, String language, String path, void Function(double) onProgress) async {
    final response = await dio.download(url('/api/${r.isChapter ? 'chapters' : 'recordings'}/${r.id}/audio/$language'), path, options: authOptions(),
      onReceiveProgress: (received, total) { if (total > 0) onProgress(received / total); });
    return response.headers;
  }
}

String readableError(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['detail'] != null) return '${data['detail']}';
    return trNow('networkError', {'error': error.message ?? error.type.name});
  }
  if (error is FormatException) return error.message;
  return error.toString();
}
