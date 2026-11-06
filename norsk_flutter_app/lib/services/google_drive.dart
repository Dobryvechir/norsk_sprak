import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../l10n/l10n.dart';
import 'media_store.dart';
import 'settings.dart';

/// A file on Google Drive.
class DriveFile {
  final String id, name, mimeType;
  const DriveFile(this.id, this.name, this.mimeType);
  factory DriveFile.fromJson(Map<String, dynamic> j) => DriveFile('${j['id']}', '${j['name'] ?? ''}', '${j['mimeType'] ?? ''}');
}

/// One page of [DriveFile]s; [nextPageToken] is null on the last page.
class DrivePage {
  final List<DriveFile> files; final String? nextPageToken;
  const DrivePage(this.files, this.nextPageToken);
}

/// An error from Google Drive, with a message for the user.
class DriveException implements Exception {
  final String message;
  const DriveException(this.message);
  @override String toString() => message;
}

/// The user's Google Drive, used straight from the app (never through our backend) with the personal
/// token from Settings. Media lives in `/media`: see [MediaKind] for the folders.
class GoogleDrive {
  static const _api = 'https://www.googleapis.com/drive/v3/files';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';
  static const folderType = 'application/vnd.google-apps.folder';

  GoogleDrive({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 10)));
  final Dio _dio;
  /// Folder ids found or created so far, by path ("media", "media/pictures", …).
  final _folders = <String, String>{};

  Options _auth([Options? o]) {
    final token = AppSettings.instance.googleDriveToken;
    if (token.isEmpty) throw DriveException(trNow('driveTokenMissing'));
    return (o ?? Options()).copyWith(headers: {...?o?.headers, 'Authorization': 'Bearer $token'});
  }

  /// Runs [call], turning failures into a [DriveException]; a failure also forgets the folder ids,
  /// in case a folder was removed meanwhile.
  Future<T> _run<T>(Future<T> Function() call) async {
    try { return await call(); }
    on DioException catch (e) { _folders.clear(); throw DriveException(_message(e)); }
  }

  static String _message(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) return trNow('driveTokenInvalid');
    var data = e.response?.data;
    if (data is List<int>) { try { data = jsonDecode(utf8.decode(data)); } catch (_) {} }
    if (data is String) { try { data = jsonDecode(data); } catch (_) {} }
    final message = data is Map && data['error'] is Map ? (data['error'] as Map)['message'] : null;
    if (message != null) return trNow('driveError', {'error': '$message'});
    if (status != null) return trNow('driveError', {'error': 'HTTP $status'});
    return trNow('networkError', {'error': e.message ?? e.type.name});
  }

  /// [text] as a quoted string for a Drive query.
  static String _quote(String text) => "'${text.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  Future<List<DriveFile>> _find(String parentId, {String? name, bool folders = false}) => _run(() async {
    final q = [
      '${_quote(parentId)} in parents', 'trashed = false',
      if (name != null) 'name = ${_quote(name)}',
      if (folders) 'mimeType = ${_quote(folderType)}',
    ].join(' and ');
    final r = await _dio.get(_api, queryParameters: {'q': q, 'fields': 'files(id,name,mimeType)', 'pageSize': 100, 'spaces': 'drive'}, options: _auth());
    return [for (final f in (r.data as Map)['files'] as List) DriveFile.fromJson(Map<String, dynamic>.from(f as Map))];
  });

  /// The id of the folder at [path] below My Drive (e.g. `media/pictures`), created when [create]
  /// is set and it doesn't exist yet; else null when it doesn't exist.
  Future<String?> folder(String path, {bool create = false}) async {
    var parent = 'root', walked = '';
    for (final part in path.split('/')) {
      walked = walked.isEmpty ? part : '$walked/$part';
      var id = _folders[walked];
      if (id == null) {
        final found = await _find(parent, name: part, folders: true);
        if (found.isNotEmpty) { id = found.first.id; }
        else if (!create) { return null; }
        else {
          id = await _run<String>(() async => '${((await _dio.post(_api, queryParameters: {'fields': 'id'}, options: _auth(),
            data: {'name': part, 'mimeType': folderType, 'parents': [parent]})).data as Map)['id']}');
        }
        _folders[walked] = id;
      }
      parent = id;
    }
    return parent;
  }

  /// The files named [name] in [folderId].
  Future<List<DriveFile>> filesNamed(String folderId, String name) => _find(folderId, name: name);

  /// One page of up to [pageSize] files in [folderId], by name.
  Future<DrivePage> list(String folderId, {String? pageToken, int pageSize = 10}) => _run(() async {
    final r = await _dio.get(_api, options: _auth(), queryParameters: {
      'q': '${_quote(folderId)} in parents and trashed = false and mimeType != ${_quote(folderType)}',
      'orderBy': 'name_natural', 'pageSize': pageSize, 'fields': 'nextPageToken,files(id,name,mimeType)', 'spaces': 'drive',
      if (pageToken != null) 'pageToken': pageToken,
    });
    final data = r.data as Map;
    return DrivePage([for (final f in data['files'] as List) DriveFile.fromJson(Map<String, dynamic>.from(f as Map))],
      data['nextPageToken'] as String?);
  });

  /// Uploads [media] as [name] into [folderId]; returns the new file's id.
  Future<String> uploadMedia(String folderId, String name, LocalMedia media, {ProgressCallback? onProgress}) async {
    final length = await media.length();
    final Object data = media.path != null && !kIsWeb ? File(media.path!).openRead() : await media.readBytes();
    return _uploadData(folderId, name, media.mimeType, data, length, onProgress);
  }

  /// Uploads [bytes] as [name] into [folderId]; returns the new file's id.
  Future<String> uploadBytes(String folderId, String name, String mimeType, Uint8List bytes) =>
    _uploadData(folderId, name, mimeType, bytes, bytes.length, null);

  /// A resumable upload: one request with the file's details, then the content itself.
  Future<String> _uploadData(String folderId, String name, String mimeType, Object data, int length, ProgressCallback? onProgress) => _run(() async {
    final start = await _dio.post(_upload, queryParameters: {'uploadType': 'resumable', 'fields': 'id'},
      data: {'name': name, 'parents': [folderId], 'mimeType': mimeType},
      options: _auth(Options(headers: {'X-Upload-Content-Type': mimeType, 'X-Upload-Content-Length': '$length'})));
    final location = start.headers.value('location');
    if (location == null) throw DriveException(trNow('driveError', {'error': 'no upload location'}));
    final r = await _dio.put(location, data: data, onSendProgress: onProgress,
      options: _auth(Options(headers: {Headers.contentTypeHeader: mimeType, Headers.contentLengthHeader: length})));
    return '${(r.data is String ? jsonDecode(r.data as String) : r.data as Map)['id']}';
  });

  /// The content of file [id].
  Future<Uint8List> downloadBytes(String id, {ProgressCallback? onProgress}) => _run(() async {
    final r = await _dio.get<List<int>>('$_api/$id', queryParameters: {'alt': 'media'}, onReceiveProgress: onProgress,
      options: _auth(Options(responseType: ResponseType.bytes)));
    final data = r.data!;
    return data is Uint8List ? data : Uint8List.fromList(data);
  });

  /// Saves the content of file [id] to [path] (not on web).
  Future<void> downloadToFile(String id, String path, {ProgressCallback? onProgress}) => _run(() async {
    await _dio.download('$_api/$id', path, queryParameters: {'alt': 'media'}, onReceiveProgress: onProgress, options: _auth());
  });

  Future<void> delete(String id) => _run(() async {
    try { await _dio.delete('$_api/$id', options: _auth()); }
    on DioException catch (e) { if (e.response?.statusCode != 404) rethrow; } // already gone
  });

  // ----- Media: /media/<kind.folder>/<name> with its icon in /media/<kind.iconFolder>/<name> -----

  Future<String?> mediaFolder(MediaKind kind, {bool create = false}) => folder('media/${kind.folder}', create: create);
  Future<String?> iconFolder(MediaKind kind, {bool create = false}) => folder('media/${kind.iconFolder}', create: create);

  /// Whether [kind] [name] (or its icon) is already on Drive.
  Future<bool> mediaExists(MediaKind kind, String name) async {
    for (final folderId in [await mediaFolder(kind), await iconFolder(kind)]) {
      if (folderId != null && (await filesNamed(folderId, name)).isNotEmpty) return true;
    }
    return false;
  }

  /// The media file [kind] [name], or null when it isn't there.
  Future<DriveFile?> findMedia(MediaKind kind, String name) async {
    final folderId = await mediaFolder(kind);
    return folderId == null ? null : (await filesNamed(folderId, name)).firstOrNull;
  }

  /// Deletes [kind] [name] and its icon.
  Future<void> deleteMedia(MediaKind kind, String name) async {
    for (final folderId in [await mediaFolder(kind), await iconFolder(kind)]) {
      if (folderId == null) continue;
      for (final f in await filesNamed(folderId, name)) { await delete(f.id); }
    }
  }
}
