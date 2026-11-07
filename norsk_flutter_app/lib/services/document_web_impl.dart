import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

// Database "norsk_documents":
//   files  key: "<folder>/<name>"  value: the document (Blob, with its media type)

const _dbName = 'norsk_documents', _files = 'files';
Future<web.IDBDatabase>? _db;

/// The open database; a failed open is tried again on the next call.
Future<web.IDBDatabase> _open() => _db ??= _connect().catchError((Object e) { _db = null; throw e; });

Future<web.IDBDatabase> _connect() {
  final done = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(_dbName, 1);
  request.onupgradeneeded = ((web.Event _) {
    final db = request.result as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_files)) db.createObjectStore(_files);
  }).toJS;
  request.onsuccess = ((web.Event _) => done.complete(request.result as web.IDBDatabase)).toJS;
  request.onerror = ((web.Event _) => done.completeError(_error(request.error, 'Could not open the document storage'))).toJS;
  request.onblocked = ((web.Event _) => done.completeError(StateError('The document storage is in use by another tab'))).toJS;
  return done.future;
}

Object _error(web.DOMException? e, String fallback) => StateError(e == null ? fallback : '${e.name}: ${e.message}');

Future<JSAny?> _result(web.IDBRequest request) {
  final done = Completer<JSAny?>();
  request.onsuccess = ((web.Event _) => done.complete(request.result)).toJS;
  request.onerror = ((web.Event _) => done.completeError(_error(request.error, 'Document storage request failed'))).toJS;
  return done.future;
}

Future<web.IDBObjectStore> _reader() async => (await _open()).transaction(_files.toJS, 'readonly').objectStore(_files);

/// Runs [work] in a read-write transaction and waits until it is committed.
Future<void> _write(void Function(web.IDBObjectStore store) work) async {
  final tx = (await _open()).transaction(_files.toJS, 'readwrite');
  final done = Completer<void>();
  tx.oncomplete = ((web.Event _) => done.complete()).toJS;
  tx.onerror = ((web.Event _) { if (!done.isCompleted) done.completeError(_error(tx.error, 'Could not save the document')); }).toJS;
  tx.onabort = ((web.Event _) { if (!done.isCompleted) done.completeError(_error(tx.error, 'Saving the document was aborted (is the storage full?)')); }).toJS;
  work(tx.objectStore(_files));
  return done.future;
}

JSString _key(String folder, String name) => '$folder/$name'.toJS;

/// The names and sizes of every document in [folder].
Future<List<(String, int)>> listDocuments(String folder) async {
  final range = web.IDBKeyRange.bound('$folder/'.toJS, '$folder/￿'.toJS);
  final store = await _reader();
  // Both requests belong to the same transaction, so they see the same documents in the same (key) order.
  final keysRequest = store.getAllKeys(range), valuesRequest = store.getAll(range);
  final keys = (await _result(keysRequest) as JSArray<JSString>).toDart;
  final values = (await _result(valuesRequest) as JSArray<web.Blob>).toDart;
  return [for (var i = 0; i < keys.length; i++) (keys[i].toDart.substring(folder.length + 1), values[i].size)];
}

Future<bool> hasDocument(String folder, String name) async =>
  (await _result((await _reader()).count(_key(folder, name))) as JSNumber).toDartInt > 0;

Future<Uint8List?> readDocument(String folder, String name) async {
  final blob = await _result((await _reader()).get(_key(folder, name))) as web.Blob?;
  if (blob == null) return null;
  return (await blob.arrayBuffer().toDart).toDart.asUint8List();
}

Future<void> writeDocument(String folder, String name, Uint8List bytes, String type) async {
  final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: type));
  await _write((s) => s.put(blob, _key(folder, name)));
  // Ask the browser not to delete the documents when space runs low (it may say no).
  try {
    final storage = web.window.navigator.storage;
    if (!(await storage.persisted().toDart).toDart) await storage.persist().toDart;
  } catch (_) {}
}

Future<void> deleteDocument(String folder, String name) => _write((s) => s.delete(_key(folder, name)));
