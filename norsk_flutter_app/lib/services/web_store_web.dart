import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

// Database "norsk_offline":
//   chapters  key: chapter id               value: the chapter JSON (string)
//   audio     key: "<chapter id>/<language>" value: the audio file (Blob, with its media type)

const _dbName = 'norsk_offline', _chapters = 'chapters', _audio = 'audio';
Future<web.IDBDatabase>? _db;

/// The open database; a failed open is tried again on the next call.
Future<web.IDBDatabase> _open() => _db ??= _connect().catchError((Object e) { _db = null; throw e; });

Future<web.IDBDatabase> _connect() {
  final done = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(_dbName, 1);
  request.onupgradeneeded = ((web.Event _) {
    final db = request.result as web.IDBDatabase;
    for (final store in [_chapters, _audio]) {
      if (!db.objectStoreNames.contains(store)) db.createObjectStore(store);
    }
  }).toJS;
  request.onsuccess = ((web.Event _) => done.complete(request.result as web.IDBDatabase)).toJS;
  request.onerror = ((web.Event _) => done.completeError(_error(request.error, 'Could not open the offline storage'))).toJS;
  request.onblocked = ((web.Event _) => done.completeError(StateError('The offline storage is in use by another tab'))).toJS;
  return done.future;
}

Object _error(web.DOMException? e, String fallback) => StateError(e == null ? fallback : '${e.name}: ${e.message}');

/// The result of [request].
Future<JSAny?> _result(web.IDBRequest request) {
  final done = Completer<JSAny?>();
  request.onsuccess = ((web.Event _) => done.complete(request.result)).toJS;
  request.onerror = ((web.Event _) => done.completeError(_error(request.error, 'Offline storage request failed'))).toJS;
  return done.future;
}

/// Runs [work] on [store] in a read-write transaction and waits until it is committed.
Future<void> _write(String store, void Function(web.IDBObjectStore store) work) async {
  final tx = (await _open()).transaction(store.toJS, 'readwrite');
  final done = Completer<void>();
  tx.oncomplete = ((web.Event _) => done.complete()).toJS;
  tx.onerror = ((web.Event _) { if (!done.isCompleted) done.completeError(_error(tx.error, 'Could not save offline')); }).toJS;
  tx.onabort = ((web.Event _) { if (!done.isCompleted) done.completeError(_error(tx.error, 'Saving offline was aborted (is the storage full?)')); }).toJS;
  work(tx.objectStore(store));
  return done.future;
}

Future<JSAny?> _read(String store, JSAny key) async =>
  _result((await _open()).transaction(store.toJS, 'readonly').objectStore(store).get(key));

/// All keys of one chapter's audio: from `"<id>/"` up to `"<id>/￿"`.
web.IDBKeyRange _audioOf(String id) => web.IDBKeyRange.bound('$id/'.toJS, '$id/￿'.toJS);

Future<void> putChapter(String id, String json) => _write(_chapters, (s) => s.put(json.toJS, id.toJS));

Future<String?> getChapter(String id) async => (await _read(_chapters, id.toJS) as JSString?)?.toDart;

Future<List<String>> chapterIds() async {
  final keys = await _result((await _open()).transaction(_chapters.toJS, 'readonly').objectStore(_chapters).getAllKeys());
  return [for (final k in (keys as JSArray<JSString>).toDart) k.toDart];
}

Future<void> putAudio(String id, String language, Uint8List bytes, String type) {
  final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: type));
  return _write(_audio, (s) => s.put(blob, '$id/$language'.toJS));
}

Future<bool> hasAudio(String id, String language) async =>
  (await _result((await _open()).transaction(_audio.toJS, 'readonly').objectStore(_audio).count('$id/$language'.toJS)) as JSNumber).toDartInt > 0;

/// A `blob:` URL of the saved audio, playable by the browser; null if it is not saved.
/// Pass it to [revokeObjectUrl] when it is no longer played.
Future<String?> audioObjectUrl(String id, String language) async {
  final blob = await _read(_audio, '$id/$language'.toJS) as web.Blob?;
  return blob == null ? null : web.URL.createObjectURL(blob);
}

void revokeObjectUrl(String url) => web.URL.revokeObjectURL(url);

/// Deletes every saved audio file of the chapter.
Future<void> removeAudio(String id) => _write(_audio, (s) => s.delete(_audioOf(id)));

/// Deletes the saved chapter: its JSON first (so it no longer counts as saved), then its audio.
Future<void> removeChapter(String id) async {
  await _write(_chapters, (s) => s.delete(id.toJS));
  await removeAudio(id);
}

/// Asks the browser not to delete the saved data when space runs low (it may say no; that is fine).
Future<void> requestPersistence() async {
  try {
    final storage = web.window.navigator.storage;
    if (!(await storage.persisted().toDart).toDart) await storage.persist().toDart;
  } catch (_) {}
}
