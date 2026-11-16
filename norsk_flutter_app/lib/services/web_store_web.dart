import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

// Database "norsk_offline":
//   chapters         key: chapter id                 value: the chapter JSON (string)
//   audio            key: "<chapter id>/<language>"   value: the audio file (Blob, with its media type)
//   recordings       key: recording id               value: the recording JSON (string)
//   recording_audio  key: "<recording id>/<language>" value: the audio file (Blob)
// Every function works on the chapters' stores, or with `recordings: true` on the recordings' stores.

const _dbName = 'norsk_offline', _version = 2;
const _chapters = 'chapters', _audio = 'audio', _recordings = 'recordings', _recordingAudio = 'recording_audio';
String _items(bool recordings) => recordings ? _recordings : _chapters;
String _audioStore(bool recordings) => recordings ? _recordingAudio : _audio;
Future<web.IDBDatabase>? _db;

/// The open database; a failed open is tried again on the next call.
Future<web.IDBDatabase> _open() => _db ??= _connect().catchError((Object e) { _db = null; throw e; });

Future<web.IDBDatabase> _connect() {
  final done = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(_dbName, _version);
  request.onupgradeneeded = ((web.Event _) {
    final db = request.result as web.IDBDatabase;
    for (final store in [_chapters, _audio, _recordings, _recordingAudio]) {
      if (!db.objectStoreNames.contains(store)) db.createObjectStore(store);
    }
  }).toJS;
  request.onsuccess = ((web.Event _) {
    final db = request.result as web.IDBDatabase;
    // Another tab with a newer version wants to upgrade: let it (this tab reopens on its next call).
    db.onversionchange = ((web.Event _) { db.close(); _db = null; }).toJS;
    done.complete(db);
  }).toJS;
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

web.IDBObjectStore _reading(web.IDBDatabase db, String store) => db.transaction(store.toJS, 'readonly').objectStore(store);

Future<JSAny?> _read(String store, JSAny key) async => _result(_reading(await _open(), store).get(key));

/// All keys of one item's audio: from `"<id>/"` up to `"<id>/￿"`.
web.IDBKeyRange _audioOf(String id) => web.IDBKeyRange.bound('$id/'.toJS, '$id/￿'.toJS);

Future<void> putChapter(String id, String json, {bool recordings = false}) =>
  _write(_items(recordings), (s) => s.put(json.toJS, id.toJS));

Future<String?> getChapter(String id, {bool recordings = false}) async =>
  (await _read(_items(recordings), id.toJS) as JSString?)?.toDart;

Future<List<String>> chapterIds({bool recordings = false}) async {
  final keys = await _result(_reading(await _open(), _items(recordings)).getAllKeys());
  return [for (final k in (keys as JSArray<JSString>).toDart) k.toDart];
}

Future<void> putAudio(String id, String language, Uint8List bytes, String type, {bool recordings = false}) {
  final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: type));
  return _write(_audioStore(recordings), (s) => s.put(blob, '$id/$language'.toJS));
}

Future<bool> hasAudio(String id, String language, {bool recordings = false}) async =>
  (await _result(_reading(await _open(), _audioStore(recordings)).count('$id/$language'.toJS)) as JSNumber).toDartInt > 0;

/// A `blob:` URL of the saved audio, playable by the browser; null if it is not saved.
/// Pass it to [revokeObjectUrl] when it is no longer played.
Future<String?> audioObjectUrl(String id, String language, {bool recordings = false}) async {
  final blob = await _read(_audioStore(recordings), '$id/$language'.toJS) as web.Blob?;
  return blob == null ? null : web.URL.createObjectURL(blob);
}

void revokeObjectUrl(String url) => web.URL.revokeObjectURL(url);

/// Deletes every saved audio file of the item.
Future<void> removeAudio(String id, {bool recordings = false}) =>
  _write(_audioStore(recordings), (s) => s.delete(_audioOf(id)));

/// Deletes the saved item: its JSON first (so it no longer counts as saved), then its audio.
Future<void> removeChapter(String id, {bool recordings = false}) async {
  await _write(_items(recordings), (s) => s.delete(id.toJS));
  await removeAudio(id, recordings: recordings);
}

/// Asks the browser not to delete the saved data when space runs low (it may say no; that is fine).
Future<void> requestPersistence() async {
  try {
    final storage = web.window.navigator.storage;
    if (!(await storage.persisted().toDart).toDart) await storage.persist().toDart;
  } catch (_) {}
}
