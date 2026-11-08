import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart' show GoogleSignInException, GoogleSignInExceptionCode;
import 'package:norsk_audio_groups/services/drive_auth.dart';
import 'package:norsk_audio_groups/services/google_drive.dart';
import 'package:norsk_audio_groups/services/media_store.dart';
import 'package:norsk_audio_groups/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Google Sign-In without Google: [silent] is the token available without showing anything.
class FakeTokens implements DriveTokenSource {
  FakeTokens(this.silent);
  String? silent;
  /// What the sign-in shown to the user gives, or throws.
  String interactive = 'good';
  Object? interactiveError;
  /// The token available silently once the rejected one is cleared.
  String? afterClear;
  var interactiveCalls = 0, signOuts = 0, disconnects = 0;
  final cleared = <String>[];
  @override bool configured = true;
  @override String? email;
  @override Future<String?> silentToken() async => silent;
  @override Future<String> interactiveToken() async {
    interactiveCalls++;
    await Future<void>.delayed(Duration.zero);
    if (interactiveError != null) throw interactiveError!;
    return interactive;
  }
  @override Future<void> clearToken(String token) async { cleared.add(token); if (afterClear != null) silent = afterClear; }
  @override Future<void> signOut() async => signOuts++;
  @override Future<void> disconnect() async => disconnects++;
}

/// A tiny in-memory Google Drive: enough of files.list / create / delete / upload for [GoogleDrive].
class FakeDrive implements HttpClientAdapter {
  /// id → {name, parent, mimeType}
  final files = <String, Map<String, String>>{};
  /// id → the file's content (its size is in [files] as `size`)
  final content = <String, List<int>>{};
  final requests = <String>[];
  var _next = 0;
  String? token;
  /// The only token accepted.
  String goodToken = 'good';
  /// Called for each request before the token is checked.
  void Function(RequestOptions)? onRequest;

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
    onRequest?.call(o);
    if (token != 'Bearer $goodToken') return json({'error': {'code': 401, 'message': 'Invalid Credentials'}}, 401);
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
  late FakeTokens tokens;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fake = FakeDrive();
    tokens = FakeTokens('good');
    drive = GoogleDrive(dio: Dio()..httpClientAdapter = fake, auth: DriveAuth(tokens));
    AppSettings.instance.driveConnected = true;
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

  test('a token Drive keeps refusing gives a readable error, after one renewal', () async {
    tokens.silent = 'expired';
    await expectLater(drive.folder('media'), throwsA(isA<DriveException>().having((e) => e.message, 'message', contains('expired'))));
    expect(fake.requests, hasLength(2));
    expect(tokens.cleared, ['expired']);
  });

  test('when not connected nothing is sent', () async {
    AppSettings.instance.driveConnected = false;
    await expectLater(drive.folder('media'), throwsA(isA<DriveException>()));
    expect(fake.requests, isEmpty);
  });

  test('an expired token is renewed silently and the request repeated', () async {
    tokens..silent = 'expired'..afterClear = 'good';
    expect(await drive.folder('media', create: true), isNotNull);
    expect(tokens.cleared, ['expired']);
    expect(tokens.interactiveCalls, 0, reason: 'nothing is shown to the user');
    expect(fake.files.values.where((f) => f['name'] == 'media'), hasLength(1));
  });

  test('a token expiring during a file upload: the upload starts over and reads the file anew', () async {
    final dir = await Directory.systemTemp.createTemp('upload');
    try {
      final file = File('${dir.path}/a.bin')..writeAsBytesSync([1, 2, 3, 4]);
      tokens.afterClear = 'new';
      var expired = false;
      fake.onRequest = (o) {
        if (o.method == 'PUT' && !expired) { expired = true; fake.goodToken = 'new'; }
      };
      final id = await drive.uploadFile('parent', 'a.bin', 'application/octet-stream', file.path);
      expect(fake.content[id], [1, 2, 3, 4]);
      expect(expired, isTrue);
      expect(tokens.cleared, ['good']);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  group('DriveAuth', () {
    test('without a silent token the sign-in is shown, and only once for parallel calls', () async {
      tokens.silent = null;
      final auth = DriveAuth(tokens);
      expect(await Future.wait([auth.token(), auth.token(), auth.token()]), ['good', 'good', 'good']);
      expect(tokens.interactiveCalls, 1);
    });

    test('a cancelled or blocked sign-in asks to reconnect', () async {
      tokens..silent = null..interactiveError = const GoogleSignInException(code: GoogleSignInExceptionCode.uiUnavailable);
      await expectLater(DriveAuth(tokens).token(), throwsA(isA<DriveException>().having((e) => e.message, 'message', contains('Reconnect'))));
    });

    test('connecting saves the connection and the address', () async {
      AppSettings.instance.driveConnected = false;
      tokens.email = 'a@b.no';
      expect(await DriveAuth(tokens).connect(), isTrue);
      expect((AppSettings.instance.driveConnected, AppSettings.instance.driveEmail), (true, 'a@b.no'));
      final prefs = await SharedPreferences.getInstance();
      expect((prefs.getBool('drive_connected'), prefs.getString('drive_email')), (true, 'a@b.no'));
    });

    test('cancelling leaves it unconnected without an error; other failures are reported', () async {
      AppSettings.instance.driveConnected = false;
      tokens.interactiveError = const GoogleSignInException(code: GoogleSignInExceptionCode.canceled);
      expect(await DriveAuth(tokens).connect(), isFalse);
      expect(AppSettings.instance.driveConnected, isFalse);
      tokens.interactiveError = const GoogleSignInException(code: GoogleSignInExceptionCode.clientConfigurationError, description: 'bad client');
      await expectLater(DriveAuth(tokens).connect(), throwsA(isA<DriveException>().having((e) => e.message, 'message', contains('bad client'))));
      expect(AppSettings.instance.driveConnected, isFalse);
    });

    test('without a client ID it cannot be connected', () async {
      tokens.configured = false;
      await expectLater(DriveAuth(tokens).connect(), throwsA(isA<DriveException>()));
      expect(tokens.interactiveCalls, 0);
    });

    test('disconnecting forgets it here even when Google cannot be reached', () async {
      await AppSettings.instance.setDriveConnection(true, email: 'a@b.no');
      await DriveAuth(_FailingDisconnect()).disconnect();
      expect((AppSettings.instance.driveConnected, AppSettings.instance.driveEmail), (false, null));
      expect((await SharedPreferences.getInstance()).getBool('drive_connected'), isFalse);
    });

    test('logging out of the app ends the connection without revoking the access', () async {
      await AppSettings.instance.setDriveConnection(true, email: 'a@b.no');
      DriveAuth(tokens).signOut();
      await Future<void>.delayed(Duration.zero);
      expect(AppSettings.instance.driveConnected, isFalse);
      expect((tokens.signOuts, tokens.disconnects), (1, 0));
    });

    test('the connection is restored on start, and the old pasted token is no longer read', () async {
      SharedPreferences.setMockInitialValues({'drive_connected': true, 'drive_email': 'a@b.no'});
      await AppSettings.instance.load();
      expect((AppSettings.instance.driveConnected, AppSettings.instance.driveEmail), (true, 'a@b.no'));
    });
  });

  test('helpers', () {
    expect(formatDuration(const Duration(seconds: 65)), '1:05');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(mimeTypeFor('x.webm', MediaKind.audio), 'audio/webm');
    expect(mimeTypeFor('x.webm', MediaKind.video), 'video/webm');
    expect(mimeTypeFor('blob:abc', MediaKind.picture), 'image/jpeg');
  });
}

class _FailingDisconnect extends FakeTokens {
  _FailingDisconnect() : super('good');
  @override Future<void> disconnect() async => throw StateError('no network');
}
