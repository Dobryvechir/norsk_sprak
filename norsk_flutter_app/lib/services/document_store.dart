import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'document_web.dart' as browser;

/// The three kinds of documents, each kept permanently on this device in `document/<folder>` and
/// synchronized with the Google Drive folder of the same path.
enum DocFolder {
  pictures('pictures', ['.png', '.jpg', '.jpeg', '.gif'], Icons.image),
  pdf('pdf', ['.pdf'], Icons.picture_as_pdf),
  sheets('sheets', ['.xlsx'], Icons.table_chart);

  const DocFolder(this.folder, this.extensions, this.icon);
  final String folder;
  /// Lower case, with the dot.
  final List<String> extensions;
  final IconData icon;

  /// `document/<folder>`: the same path on this device and on Google Drive.
  String get path => 'document/$folder';

  bool accepts(String fileName) => extensions.contains(p.extension(fileName).toLowerCase());

  /// The folder for [fileName] by its extension, or null when it is not a supported document.
  static DocFolder? forFile(String fileName) {
    for (final f in values) { if (f.accepts(fileName)) return f; }
    return null;
  }

  /// Every supported extension, without the dot (for a file picker).
  static List<String> get allExtensions => [for (final f in values) for (final e in f.extensions) e.substring(1)];
}

/// The media type of a document named [fileName].
String documentMimeType(String fileName) => switch (p.extension(fileName).toLowerCase()) {
  '.png' => 'image/png', '.jpg' || '.jpeg' => 'image/jpeg', '.gif' => 'image/gif',
  '.pdf' => 'application/pdf',
  '.xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  _ => 'application/octet-stream',
};

/// A document saved on this device.
class DocEntry {
  final String name;
  final int size;
  const DocEntry(this.name, this.size);
}

/// Whether [name] can be a document's file name: not empty, no path separators, not hidden.
bool validDocumentName(String name) =>
  name.trim().isNotEmpty && !name.contains('/') && !name.contains(r'\') && !name.startsWith('.');

/// "1.5 MB", "820 KB", "12 B".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024; var i = 0;
  while (value >= 1024 && i < units.length - 1) { value /= 1024; i++; }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[i]}';
}

/// The documents kept permanently on this device: files in `<app documents>/document/<folder>`,
/// or on web in the browser's IndexedDB (see document_web.dart).
/// Only names with the folder's extensions count as documents (so half-written `.partial` files don't).
abstract class DocumentStore {
  static DocumentStore instance = kIsWeb ? _WebDocumentStore() : FileDocumentStore();

  /// The documents in [folder], sorted by name (case-insensitive).
  Future<List<DocEntry>> list(DocFolder folder);
  Future<bool> exists(DocFolder folder, String name);
  Future<Uint8List> read(DocFolder folder, String name);
  /// The file of a document (it need not exist yet); null where documents are not files (web).
  Future<String?> filePath(DocFolder folder, String name);
  /// Saves [bytes] as [name], replacing a document of that name.
  Future<void> write(DocFolder folder, String name, Uint8List bytes);
  /// Saves a copy of the file at [sourcePath] as [name] (not on web), replacing a document of that name.
  Future<void> copyFile(DocFolder folder, String name, String sourcePath);
  /// Moves the file at [sourcePath] (not on web) to be the document [name], replacing one of that name.
  Future<void> moveFile(DocFolder folder, String name, String sourcePath);
  Future<void> delete(DocFolder folder, String name);

  static List<DocEntry> sorted(List<DocEntry> entries) =>
    entries..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// Documents as files in `<root>/document/<folder>`; [root] defaults to the app's documents folder.
class FileDocumentStore extends DocumentStore {
  FileDocumentStore({this.root});
  final String? root;

  Future<Directory> _dir(DocFolder folder) async {
    final base = root ?? (await getApplicationDocumentsDirectory()).path;
    final dir = Directory(p.joinAll([base, 'document', folder.folder]));
    await dir.create(recursive: true);
    return dir;
  }

  @override Future<String> filePath(DocFolder folder, String name) async => p.join((await _dir(folder)).path, name);

  @override Future<List<DocEntry>> list(DocFolder folder) async {
    final result = <DocEntry>[];
    await for (final e in (await _dir(folder)).list()) {
      final name = p.basename(e.path);
      if (e is File && folder.accepts(name) && !name.startsWith('.')) {
        try { result.add(DocEntry(name, await e.length())); } catch (_) {}
      }
    }
    return DocumentStore.sorted(result);
  }

  @override Future<bool> exists(DocFolder folder, String name) async => File(await filePath(folder, name)).exists();

  @override Future<Uint8List> read(DocFolder folder, String name) async => File(await filePath(folder, name)).readAsBytes();

  /// Writes through a `.partial` file, so a broken write never leaves half a document.
  Future<void> _replace(String target, Future<void> Function(File partial) fill) async {
    final partial = File('$target.partial');
    try { await fill(partial); await partial.rename(target); }
    catch (_) { try { await partial.delete(); } catch (_) {} rethrow; }
  }

  @override Future<void> write(DocFolder folder, String name, Uint8List bytes) async =>
    _replace(await filePath(folder, name), (f) => f.writeAsBytes(bytes, flush: true));

  @override Future<void> copyFile(DocFolder folder, String name, String sourcePath) async =>
    _replace(await filePath(folder, name), (f) => File(sourcePath).copy(f.path));

  @override Future<void> moveFile(DocFolder folder, String name, String sourcePath) async {
    final target = await filePath(folder, name);
    try { await File(sourcePath).rename(target); }
    catch (_) { await copyFile(folder, name, sourcePath); try { await File(sourcePath).delete(); } catch (_) {} } // another drive
  }

  @override Future<void> delete(DocFolder folder, String name) async {
    final f = File(await filePath(folder, name));
    if (await f.exists()) await f.delete();
  }
}

class _WebDocumentStore extends DocumentStore {
  @override Future<List<DocEntry>> list(DocFolder folder) async => DocumentStore.sorted([
    for (final (name, size) in await browser.listDocuments(folder.folder)) if (folder.accepts(name)) DocEntry(name, size)]);
  @override Future<bool> exists(DocFolder folder, String name) => browser.hasDocument(folder.folder, name);
  @override Future<Uint8List> read(DocFolder folder, String name) async =>
    await browser.readDocument(folder.folder, name) ?? (throw StateError('"$name" is not on this device'));
  @override Future<String?> filePath(DocFolder folder, String name) async => null;
  @override Future<void> write(DocFolder folder, String name, Uint8List bytes) =>
    browser.writeDocument(folder.folder, name, bytes, documentMimeType(name));
  @override Future<void> copyFile(DocFolder folder, String name, String sourcePath) =>
    throw UnsupportedError('No files on web');
  @override Future<void> moveFile(DocFolder folder, String name, String sourcePath) =>
    throw UnsupportedError('No files on web');
  @override Future<void> delete(DocFolder folder, String name) => browser.deleteDocument(folder.folder, name);
}
