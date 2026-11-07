import 'document_store.dart';
import 'google_drive.dart';

/// A document that is on this device and on Google Drive with different sizes: left alone by
/// [DocumentSync] and listed for the user.
class SyncConflict {
  final DocFolder folder;
  final String name;
  final int localSize, driveSize;
  const SyncConflict(this.folder, this.name, this.localSize, this.driveSize);
}

/// What one synchronization did.
class SyncReport {
  int uploaded = 0, downloaded = 0, unchanged = 0;
  final conflicts = <SyncConflict>[];
  /// `<folder>/<name>: <error>` for each file that failed.
  final errors = <String>[];
}

/// Synchronizes the documents on this device (`document/pictures`, `document/pdf`, `document/sheets`)
/// with the folders of the same path on the user's Google Drive (created when missing):
/// - only here → uploaded to Drive; only on Drive → downloaded here;
/// - on both with the same size → left alone; with different sizes → a [SyncConflict], left alone.
/// Only files with the folder's extensions count; Google's own formats (no size) are skipped, and of
/// several Drive files with one name, only the first counts. Nothing is ever deleted.
class DocumentSync {
  DocumentSync(this.drive, this.store);
  final GoogleDrive drive;
  final DocumentStore store;

  /// Runs the synchronization. [onProgress] gets the number of transfers done, their total and the
  /// file being transferred. A failure to reach Drive at all (e.g. a bad token) throws [DriveException];
  /// a failing file is noted in [SyncReport.errors] and the rest go on.
  Future<SyncReport> run({void Function(int done, int total, String name)? onProgress}) async {
    final report = SyncReport();
    final uploads = <(DocFolder, String, String)>[]; // folder, name, Drive folder id
    final downloads = <(DocFolder, DriveFile)>[];
    // First compare everything, so the number of transfers is known before any starts.
    for (final folder in DocFolder.values) {
      final folderId = (await drive.folder(folder.path, create: true))!;
      final local = {for (final e in await store.list(folder)) e.name: e.size};
      final remote = <String, DriveFile>{};
      for (final f in await drive.listAll(folderId)) {
        if (f.size != null && folder.accepts(f.name) && validDocumentName(f.name)) remote.putIfAbsent(f.name, () => f);
      }
      for (final MapEntry(key: name, value: size) in local.entries) {
        final there = remote[name];
        if (there == null) { uploads.add((folder, name, folderId)); }
        else if (there.size == size) { report.unchanged++; }
        else { report.conflicts.add(SyncConflict(folder, name, size, there.size!)); }
      }
      for (final f in remote.values) { if (!local.containsKey(f.name)) downloads.add((folder, f)); }
    }
    final total = uploads.length + downloads.length;
    var done = 0;
    void step(String name) => onProgress?.call(done, total, name);
    for (final (folder, name, folderId) in uploads) {
      step(name);
      try {
        final path = await store.filePath(folder, name);
        path != null
          ? await drive.uploadFile(folderId, name, documentMimeType(name), path)
          : await drive.uploadBytes(folderId, name, documentMimeType(name), await store.read(folder, name));
        report.uploaded++;
      } catch (e) { report.errors.add('${folder.path}/$name: $e'); }
      done++;
    }
    for (final (folder, file) in downloads) {
      step(file.name);
      try {
        final path = await store.filePath(folder, file.name);
        if (path != null) {
          // Downloaded beside the target first, so a broken download leaves no half document.
          final partial = '$path.partial';
          await drive.downloadToFile(file.id, partial);
          await store.moveFile(folder, file.name, partial);
        } else {
          await store.write(folder, file.name, await drive.downloadBytes(file.id));
        }
        report.downloaded++;
      } catch (e) { report.errors.add('${folder.path}/${file.name}: $e'); }
      done++;
    }
    onProgress?.call(done, total, '');
    return report;
  }
}
