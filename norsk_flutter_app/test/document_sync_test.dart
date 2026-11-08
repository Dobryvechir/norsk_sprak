import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/services/doc_links.dart';
import 'package:norsk_audio_groups/services/document_store.dart';
import 'package:norsk_audio_groups/services/document_sync.dart';
import 'package:norsk_audio_groups/services/google_drive.dart';
import 'package:norsk_audio_groups/services/settings.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:norsk_audio_groups/services/drive_auth.dart';
import 'google_drive_test.dart' show FakeDrive, FakeTokens;

/// Documents kept in memory, like on web (no files).
class MemoryDocumentStore extends DocumentStore {
  final docs = <String, Uint8List>{};
  String _key(DocFolder f, String name) => '${f.folder}/$name';
  @override Future<List<DocEntry>> list(DocFolder folder) async => DocumentStore.sorted([
    for (final e in docs.entries) if (e.key.startsWith('${folder.folder}/')) DocEntry(e.key.substring(folder.folder.length + 1), e.value.length)]);
  @override Future<bool> exists(DocFolder folder, String name) async => docs.containsKey(_key(folder, name));
  @override Future<Uint8List> read(DocFolder folder, String name) async => docs[_key(folder, name)]!;
  @override Future<String?> filePath(DocFolder folder, String name) async => null;
  @override Future<void> write(DocFolder folder, String name, Uint8List bytes) async => docs[_key(folder, name)] = bytes;
  @override Future<void> copyFile(DocFolder folder, String name, String sourcePath) => throw UnsupportedError('no files');
  @override Future<void> moveFile(DocFolder folder, String name, String sourcePath) => throw UnsupportedError('no files');
  @override Future<void> delete(DocFolder folder, String name) async => docs.remove(_key(folder, name));
}

Uint8List bytes(int n) => Uint8List.fromList(List.filled(n, 7));

void main() {
  late FakeDrive fake;
  late GoogleDrive drive;
  late FakeTokens tokens;
  setUp(() {
    fake = FakeDrive();
    tokens = FakeTokens('good');
    drive = GoogleDrive(dio: Dio()..httpClientAdapter = fake, auth: DriveAuth(tokens));
    AppSettings.instance.driveConnected = true;
  });

  /// The Drive folder `document/<folder>`, created.
  Future<String> driveFolder(DocFolder f) async => (await drive.folder(f.path, create: true))!;
  Map<String, int> driveFiles(String folderId) => {
    for (final f in fake.files.values) if (f['parent'] == folderId) f['name']!: int.parse(f['size'] ?? '-1')};

  for (final files in [false, true]) {
    test('copies missing files both ways, skips equal sizes and reports different sizes (${files ? 'files' : 'web'})', () async {
      final DocumentStore store;
      Directory? tmp;
      if (files) { tmp = await Directory.systemTemp.createTemp('docs'); store = FileDocumentStore(root: tmp.path); }
      else { store = MemoryDocumentStore(); }
      try {
        final pictures = await driveFolder(DocFolder.pictures), pdf = await driveFolder(DocFolder.pdf);
        await store.write(DocFolder.pictures, 'local.jpg', bytes(3));     // only here → uploaded
        await store.write(DocFolder.pictures, 'same.png', bytes(5));      // equal → skipped
        fake.add('same.png', pictures, mimeType: 'image/png', bytes: bytes(5));
        await store.write(DocFolder.pdf, 'differs.pdf', bytes(10));       // different size → conflict
        fake.add('differs.pdf', pdf, mimeType: 'application/pdf', bytes: bytes(12));
        fake.add('remote.pdf', pdf, mimeType: 'application/pdf', bytes: bytes(4)); // only there → downloaded
        fake.add('notes.txt', pdf, mimeType: 'text/plain', bytes: bytes(1));        // wrong type → ignored
        fake.add('Doc', pdf, mimeType: 'application/vnd.google-apps.document');     // no size → ignored

        final progress = <(int, int)>[];
        final report = await DocumentSync(drive, store).run(onProgress: (d, t, _) => progress.add((d, t)));

        expect(report.errors, isEmpty);
        expect((report.uploaded, report.downloaded, report.unchanged), (1, 1, 1));
        expect(report.conflicts.single.name, 'differs.pdf');
        expect((report.conflicts.single.localSize, report.conflicts.single.driveSize), (10, 12));
        expect(progress.last, (2, 2));
        expect(driveFiles(pictures), {'local.jpg': 3, 'same.png': 5});
        expect(fake.files.values.singleWhere((f) => f['name'] == 'local.jpg')['mimeType'], 'image/jpeg');
        expect((await store.list(DocFolder.pdf)).map((e) => (e.name, e.size)), [('differs.pdf', 10), ('remote.pdf', 4)]);
        expect(await store.read(DocFolder.pdf, 'differs.pdf'), bytes(10), reason: 'a conflict changes nothing');
        expect(driveFiles(pdf)['differs.pdf'], 12);
        if (tmp != null) {
          expect(await tmp.list(recursive: true).where((e) => e.path.endsWith('.partial')).isEmpty, isTrue);
          expect(File(p.join(tmp.path, 'document', 'pdf', 'remote.pdf')).existsSync(), isTrue);
        }

        // A second run finds everything in place.
        final again = await DocumentSync(drive, store).run();
        expect((again.uploaded, again.downloaded, again.unchanged, again.conflicts.length), (0, 0, 3, 1));
      } finally {
        await tmp?.delete(recursive: true);
      }
    });
  }

  test('a bad token stops the synchronization with a readable error', () async {
    tokens.silent = 'expired';
    expect(DocumentSync(drive, MemoryDocumentStore()).run(), throwsA(isA<DriveException>()));
  });

  test('the file store keeps only documents of the folder, and replaces by name', () async {
    final tmp = await Directory.systemTemp.createTemp('docs');
    try {
      final store = FileDocumentStore(root: tmp.path);
      await store.write(DocFolder.sheets, 'b.xlsx', bytes(2));
      await store.write(DocFolder.sheets, 'A.xlsx', bytes(1));
      await store.write(DocFolder.sheets, 'A.xlsx', bytes(3));
      File(p.join(tmp.path, 'document', 'sheets', 'x.xlsx.partial')).writeAsBytesSync([1]);
      File(p.join(tmp.path, 'document', 'sheets', 'readme.txt')).writeAsBytesSync([1]);
      expect((await store.list(DocFolder.sheets)).map((e) => (e.name, e.size)), [('A.xlsx', 3), ('b.xlsx', 2)]);
      await store.delete(DocFolder.sheets, 'A.xlsx');
      expect(await store.exists(DocFolder.sheets, 'A.xlsx'), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('helpers', () {
    expect(DocFolder.forFile('Photo.JPEG'), DocFolder.pictures);
    expect(DocFolder.forFile('table.xlsx'), DocFolder.sheets);
    expect(DocFolder.forFile('old.xls'), isNull);
    expect(documentMimeType('a.gif'), 'image/gif');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(validDocumentName('a/b.png'), isFalse);
    expect(normalizeLink('example.com/x'), 'https://example.com/x');
    expect(normalizeLink('http://a.no'), 'http://a.no');
    expect(normalizeLink('ftp://a.no'), isNull);
    expect(normalizeLink('not a link'), isNull);
  });

  test('links: create, read, update and delete', () async {
    SharedPreferences.setMockInitialValues({});
    final b = await DocLinks.create('beta', 'https://b.no');
    await DocLinks.create('Alpha', 'https://a.no');
    expect((await DocLinks.all()).map((l) => l.name), ['Alpha', 'beta']);
    await DocLinks.update(DocLink(b.id, 'Beta', 'https://b2.no'));
    expect((await DocLinks.all()).last.url, 'https://b2.no');
    await DocLinks.delete(b.id);
    expect((await DocLinks.all()).map((l) => l.name), ['Alpha']);
  });
}
