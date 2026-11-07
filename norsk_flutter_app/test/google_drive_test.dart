import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/services/google_drive.dart';
import 'package:norsk_audio_groups/services/media_store.dart';
import 'package:norsk_audio_groups/services/settings.dart';

/// A tiny in-memory Google Drive: enough of files.list / create / delete / upload for [GoogleDrive].
class FakeDrive implements HttpClientAdapter {
  /// id → {name, parent, mimeType}
  final files = <String, Map<String, String>>{};
  /// id → the file's content (its size is in [files] as `size`)
  final content = <String, List<int>>{};
  final requests = <String>[];
  var _next = 0;
  String? token;

  String add(String name, String parent, {String mimeType = GoogleDrive.folderType, List<int>? bytes}) {
    final id = 'id${_next++}';
    files[id] = {'name': name, 'parent': parent, 'mimeType': mimeType, if (bytes != null) 'size': '${bytes.length}'};
    if (bytes != null) content[id] = bytes;
    return id;
  }

  ResponseBody json(Object body, [int status = 200, Map<String, List<String>> headers = const {}]) =>
    ResponseBody.fromString(jsonEncode(body), status, headers: {'content-type': ['application/json'], ...headers});

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests.add('${o.method} ${o.uri.path}');
    token = o.headers['Authorization'] as String?;
    if (token != 'Bearer good') return json({'error': {'code': 401, 'message': 'Invalid Credentials'}}, 401);
    final path = o.uri.path;
    if (o.method == 'GET' && path == '/drive/v3/files') {
      final q = o.uri.queryParameters['q']!;
      final parent = RegExp(r"^'([^']*)' in parents").firstMatch(q)!.group(1)!;
      final name = RegExp(r"name = '((?:[^'\\]|\\.)*)'").firstMatch(q)?.group(1)?.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
      final onlyFolders = q.contains("mimeType = '${GoogleDrive.folderType}'");
      final noFolders = q.contains("mimeType != '${GoogleDrive.folderType}'");
      final found = [
        for (final e in files.entries)
          if (e.value['parent'] == parent && (name == null || e.value['name'] == name)
            && (!onlyFolders || e.value['mimeType'] == GoogleDrive.folderType)
            && (!noFolders || e.value['mimeType'] != GoogleDrive.folderType))
            {'id': e.key, ...e.value},
      ]..sort((a, b) => a['name']!.compareTo(b['name']!));
      final size = int.parse(o.uri.queryParameters['pageSize'] ?? '100');
      final start = int.parse(o.uri.queryParameters['pageToken'] ?? '0');
      final page = found.skip(start).take(size).toList();
      return json({'files': page, if (start + size < found.length) 'nextPageToken': '${start + size}'});
    }
    if (o.method == 'POST' && path == '/drive/v3/files') {
      final d = o.data as Map;
      return json({'id': add('${d['name']}', '${(d['parents'] as List).first}', mimeType: '${d['mimeType']}')});
    }
    if (o.method == 'POST' && path == '/upload/drive/v3/files') {
      final d = o.data as Map;
      final id = add('${d['name']}', '${(d['parents'] as List).first}', mimeType: '${d['mimeType']}');
      return json({}, 200, {'location': ['https://upload.example/session/$id']});
    }
    if (o.method == 'PUT' && path.startsWith('/session/')) {
      final id = path.split('/').last, bytes = <int>[];
      if (body != null) { await for (final chunk in body) { bytes.addAll(chunk); } }
      content[id] = bytes;
      files[id]!['size'] = '${bytes.length}';
      return json({'id': id});
    }
    if (o.method == 'GET' && path.startsWith('/drive/v3/files/') && o.uri.queryParameters['alt'] == 'media') {
      final bytes = content[path.split('/').last];
      return bytes == null ? json({'error': {'message': 'File not found'}}, 404) : ResponseBody.fromBytes(bytes, 200);
    }
    if (o.method == 'DELETE') {
      return files.remove(path.split('/').last) == null ? json({'error': {'message': 'File not found'}}, 404) : json({}, 204);
    }
    return json({'error': {'message': 'unexpected ${o.method} $path'}}, 400);
  }

  @override void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeDrive fake;
  late GoogleDrive drive;
  setUp(() {
    fake = FakeDrive();
    drive = GoogleDrive(dio: Dio()..httpClientAdapter = fake);
    AppSettings.instance.googleDriveToken = 'good';
  });

  test('folders are created when missing and reused afterwards', () async {
    expect(await drive.folder('media/pictures'), isNull);
    final id = await drive.folder('media/pictures', create: true);
    expect(fake.files[id]!['name'], 'pictures');
    final media = fake.files.entries.singleWhere((e) => e.value['name'] == 'media');
    expect(media.value['parent'], 'root');
    expect(fake.files[id]!['parent'], media.key);
    fake.requests.clear();
    expect(await drive.folder('media/pictures', create: true), id);
    expect(fake.requests, isEmpty, reason: 'folder ids are remembered');
  });

  test('saved media is listed by its icon, found, and deleted together with the icon', () async {
    final pictures = (await drive.mediaFolder(MediaKind.picture, create: true))!;
    final icons = (await drive.iconFolder(MediaKind.picture, create: true))!;
    await drive.uploadBytes(pictures, "Bob's cat", 'image/jpeg', Uint8List.fromList([1, 2, 3]));
    await drive.uploadBytes(icons, "Bob's cat", 'image/png', Uint8List.fromList([4]));
    expect(await drive.mediaExists(MediaKind.picture, "Bob's cat"), isTrue);
    expect(await drive.mediaExists(MediaKind.picture, 'Dog'), isFalse);
    expect((await drive.findMedia(MediaKind.picture, "Bob's cat"))!.mimeType, 'image/jpeg');

    await drive.deleteMedia(MediaKind.picture, "Bob's cat");
    expect(await drive.mediaExists(MediaKind.picture, "Bob's cat"), isFalse);
    expect(fake.files.values.where((f) => f['mimeType'] != GoogleDrive.folderType), isEmpty);
  });

  test('lists 10 per page with a token for the next page', () async {
    final icons = (await drive.iconFolder(MediaKind.audio, create: true))!;
    for (var i = 0; i < 12; i++) { fake.add('a${i.toString().padLeft(2, '0')}', icons, mimeType: 'image/png'); }
    final first = await drive.list(icons);
    expect(first.files.map((f) => f.name), [for (var i = 0; i < 10; i++) 'a0$i']);
    expect(first.nextPageToken, isNotNull);
    final second = await drive.list(icons, pageToken: first.nextPageToken);
    expect(second.files.map((f) => f.name), ['a10', 'a11']);
    expect(second.nextPageToken, isNull);
  });

  test('a bad token gives a readable error', () async {
    AppSettings.instance.googleDriveToken = 'expired';
    expect(drive.folder('media'), throwsA(isA<DriveException>().having((e) => e.message, 'message', contains('expired'))));
  });

  test('without a token nothing is sent', () async {
    AppSettings.instance.googleDriveToken = '';
    await expectLater(drive.folder('media'), throwsA(isA<DriveException>()));
    expect(fake.requests, isEmpty);
  });

  test('helpers', () {
    expect(formatDuration(const Duration(seconds: 65)), '1:05');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(mimeTypeFor('x.webm', MediaKind.audio), 'audio/webm');
    expect(mimeTypeFor('x.webm', MediaKind.video), 'video/webm');
    expect(mimeTypeFor('blob:abc', MediaKind.picture), 'image/jpeg');
  });
}
