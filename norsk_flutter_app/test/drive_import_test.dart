import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/services/drive_auth.dart';
import 'package:norsk_audio_groups/services/drive_import.dart';
import 'package:norsk_audio_groups/services/google_drive.dart';
import 'package:norsk_audio_groups/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Tokens implements DriveTokenSource {
  @override bool get configured => true;
  @override String? get email => null;
  @override Future<String?> silentToken() async => 'good';
  @override Future<String> interactiveToken() async => 'good';
  @override Future<void> clearToken(String token) async {}
  @override Future<void> signOut() async {}
  @override Future<void> disconnect() async {}
}

/// Just enough of Drive for export, copy (with conversion), download, delete and listing.
class _Drive implements HttpClientAdapter {
  final requests = <String>[];
  final deleted = <String>[];
  Map<String, dynamic>? copyBody;
  Map<String, String>? listQuery;
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    final path = o.uri.path;
    requests.add('${o.method} $path ${o.uri.queryParameters['mimeType'] ?? ''}'.trim());
    ResponseBody json(Object b) => ResponseBody.fromString(jsonEncode(b), 200, headers: {'content-type': ['application/json']});
    if (o.method == 'POST' && path.endsWith('/copy')) { copyBody = Map<String, dynamic>.from(o.data as Map); return json({'id': 'tmp'}); }
    if (o.method == 'GET' && path.endsWith('/export')) return ResponseBody.fromBytes(utf8.encode('exported ${path.split('/')[4]}'), 200);
    if (o.method == 'GET' && o.uri.queryParameters['alt'] == 'media') return ResponseBody.fromBytes([1, 2, 3], 200);
    if (o.method == 'DELETE') { deleted.add(path.split('/').last); return json({}); }
    if (o.method == 'GET' && path == '/drive/v3/files') {
      listQuery = o.uri.queryParameters;
      return json({'files': [
        {'id': 'f1', 'name': 'Docs', 'mimeType': GoogleDrive.folderType},
        {'id': 's1', 'name': 'Link to sheet', 'mimeType': GoogleDrive.shortcutType,
          'shortcutDetails': {'targetId': 'sheet9', 'targetMimeType': googleSpreadsheet}},
      ], 'nextPageToken': 'p2'});
    }
    return ResponseBody.fromString('unexpected', 400);
  }
  @override void close({bool force = false}) {}
}

DriveFile file(String name, String mimeType) => DriveFile('id', name, mimeType);
const documents = ImportTarget(['.png', '.jpg', '.jpeg', '.gif', '.pdf', '.xlsx']);

void main() {
  group('planImport', () {
    String? plan(String name, String type, ImportTarget target) {
      final p = planImport(file(name, type), target);
      return p == null ? null : '${p.method.name} ${p.name} ${p.mimeType}';
    }

    test('Google Docs, Sheets, Slides and Drawings are exported to what the target takes', () {
      expect(plan('Notes', googleDocument, documents), 'export Notes.pdf application/pdf');
      expect(plan('Words', googleSpreadsheet, documents), 'export Words.xlsx application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      expect(plan('Talk', googlePresentation, documents), 'export Talk.pdf application/pdf');
      expect(plan('Map', googleDrawing, documents), 'export Map.png image/png');
      expect(plan('Map', googleDrawing, ImportTarget.pictures), 'export Map.png image/png');
      expect(plan('Words', googleSpreadsheet, const ImportTarget(['.pdf'])), 'export Words.pdf application/pdf');
      expect(plan('Words', googleSpreadsheet, const ImportTarget.any()), startsWith('export Words.xlsx'));
    });

    test('Google files with nothing to export, and folders, are refused', () {
      expect(plan('Quiz', 'application/vnd.google-apps.form', documents), isNull);
      expect(plan('Site', 'application/vnd.google-apps.site', const ImportTarget.any()), isNull);
      expect(plan('Docs', GoogleDrive.folderType, const ImportTarget.any()), isNull);
      expect(plan('Notes', googleDocument, ImportTarget.audio), isNull);
    });

    test('accepted files are downloaded, with the extension their type calls for', () {
      expect(plan('a.jpeg', 'image/jpeg', documents), 'download a.jpeg image/jpeg');
      expect(plan('a.JPG', 'image/pjpeg', documents), 'download a.JPG image/jpeg');
      expect(plan('scan', 'application/x-pdf', documents), 'download scan.pdf application/pdf');
      expect(plan('photo.png', 'image/jpeg', documents), 'download photo.jpg image/jpeg');
      expect(plan('list.xlsx', 'application/octet-stream', documents), 'download list.xlsx application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      expect(plan('a.jfif', 'image/jpeg', ImportTarget.pictures), 'download a.jpg image/jpeg');
    });

    test('audio types under any of their names', () {
      expect(plan('song', 'audio/x-m4a', ImportTarget.audio), 'download song.m4a audio/mp4');
      expect(plan('song', 'audio/mp3', ImportTarget.audio), 'download song.mp3 audio/mpeg');
      expect(plan('song', 'audio/x-wav', ImportTarget.audio), 'download song.wav audio/wav');
      expect(plan('song', 'audio/x-flac', ImportTarget.audio), 'download song.flac audio/flac');
      expect(plan('song', 'application/ogg', ImportTarget.audio), 'download song.ogg audio/ogg');
      expect(plan('song', 'audio/x-aac', ImportTarget.audio), 'download song.aac audio/aac');
      expect(plan('talk.opus', 'audio/ogg', ImportTarget.audio), 'download talk.opus audio/opus', reason: 'the name is trusted between audio types');
      expect(plan('talk.m4a', 'video/mp4', ImportTarget.audio), 'download talk.m4a audio/mp4');
      expect(plan('clip.m4v', 'video/x-m4v', ImportTarget.audio), 'download clip.mp4 video/x-m4v');
      expect(plan('memo.amr', 'audio/amr', ImportTarget.audio), isNull, reason: 'audio can\'t be converted');
      expect(plan('clip.mov', 'video/quicktime', ImportTarget.audio), isNull);
    });

    test('other pictures become PNG', () {
      for (final (name, type) in [('a.webp', 'image/webp'), ('a.heic', 'image/heif'), ('a.bmp', 'image/x-ms-bmp'),
          ('a.tif', 'image/tiff'), ('a.svg', 'image/svg+xml'), ('a.dng', 'image/x-adobe-dng'), ('a', 'image/x-unknown')]) {
        expect(plan(name, type, documents), 'picture a.png image/png', reason: type);
      }
    });

    test('Office, OpenDocument, CSV and text files are converted on Drive', () {
      expect(plan('old.xls', 'application/vnd.ms-excel', documents), 'convert old.xlsx application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      expect(plan('t.ods', 'application/vnd.oasis.opendocument.spreadsheet', documents), startsWith('convert t.xlsx'));
      expect(plan('t.csv', 'text/csv', documents), startsWith('convert t.xlsx'));
      expect(plan('t.csv', 'text/plain', documents), startsWith('convert t.xlsx'), reason: 'the name tells it is CSV');
      expect(plan('t.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', documents), 'convert t.pdf application/pdf');
      expect(plan('t.doc', 'application/msword', documents), 'convert t.pdf application/pdf');
      expect(plan('t.pptx', 'application/vnd.openxmlformats-officedocument.presentationml.presentation', documents), 'convert t.pdf application/pdf');
      expect(plan('t.txt', 'text/plain', documents), 'convert t.pdf application/pdf');
      expect(plan('t.rtf', 'text/rtf', documents), 'convert t.pdf application/pdf');
      expect(plan('t.zip', 'application/zip', documents), isNull);
    });

    test('any file is taken as it is, under its right name', () {
      expect(plan('t.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', const ImportTarget.any()),
        'download t.docx application/vnd.openxmlformats-officedocument.wordprocessingml.document');
      expect(plan('clip', 'video/quicktime', const ImportTarget.any()), 'download clip.mov video/quicktime');
      expect(plan('data', 'application/x-thing', const ImportTarget.any()), 'download data application/x-thing');
    });

    test('media type names', () {
      expect(canonicalMimeType('Audio/X-M4A; codecs=mp4a'), 'audio/mp4');
      expect(extensionForMimeType('image/x-png'), '.png');
      expect(mimeTypeForExtension('a.JPEG'), 'image/jpeg');
      expect(mimeTypeForExtension('a.unknown'), isNull);
    });
  });

  group('DriveImporter', () {
    late _Drive fake;
    late DriveImporter importer;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppSettings.instance.driveConnected = true;
      fake = _Drive();
      importer = DriveImporter(GoogleDrive(dio: Dio()..httpClientAdapter = fake, auth: DriveAuth(_Tokens())));
    });

    test('a Google file is exported', () async {
      final f = DriveFile('doc1', 'Notes', googleDocument);
      final got = await importer.fetch(f, planImport(f, documents)!);
      expect((got.name, got.mimeType, utf8.decode(got.bytes)), ('Notes.pdf', 'application/pdf', 'exported doc1'));
      expect(fake.requests, ['GET /drive/v3/files/doc1/export application/pdf']);
    });

    test('an Office file is converted through a temporary Google copy, which is deleted', () async {
      final f = DriveFile('xls1', 'old.xls', 'application/vnd.ms-excel');
      final got = await importer.fetch(f, planImport(f, documents)!);
      expect(got.name, 'old.xlsx');
      expect(utf8.decode(got.bytes), 'exported tmp');
      expect(fake.copyBody!['mimeType'], googleSpreadsheet);
      expect(fake.deleted, ['tmp']);
    });

    test('an accepted file is downloaded as it is', () async {
      final f = DriveFile('a1', 'song', 'audio/x-m4a');
      final got = await importer.fetch(f, planImport(f, ImportTarget.audio)!);
      expect(got.name, 'song.m4a');
      expect(got.bytes, [1, 2, 3]);
    });

    test('browsing lists folders first and follows shortcuts', () async {
      final page = await importer.drive.browse(folderId: 'f0');
      expect(fake.listQuery!['q'], "trashed = false and 'f0' in parents");
      expect(fake.listQuery!['orderBy'], 'folder,name_natural');
      expect(page.files.first.isFolder, isTrue);
      expect((page.files[1].id, page.files[1].name, page.files[1].mimeType), ('sheet9', 'Link to sheet', googleSpreadsheet));
      expect(page.nextPageToken, 'p2');
      await importer.drive.browse(search: "Bob's");
      expect(fake.listQuery!['q'], r"trashed = false and name contains 'Bob\'s'");
      await importer.drive.browse(sharedWithMe: true);
      expect(fake.listQuery!['q'], 'trashed = false and sharedWithMe = true');
    });
  });
}
