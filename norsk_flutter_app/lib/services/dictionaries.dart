import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'api.dart';
import 'document_web.dart' as browser;
import 'word_dictionary.dart';

/// A dictionary the server offers: `GET /api/dictionaries`.
class DictionaryInfo {
  final String lang, url;
  /// The file's size in bytes.
  final int size;
  const DictionaryInfo(this.lang, this.url, this.size);
  factory DictionaryInfo.fromJson(Map<String, dynamic> j) => DictionaryInfo('${j['lang']}', '${j['url']}', (j['size'] as num).toInt());
}

/// One language on the Dictionaries page: offered by the server, saved on this device, or both.
class DictionaryStatus {
  final String lang;
  final DictionaryInfo? remote;
  final int? localSize;
  const DictionaryStatus(this.lang, this.remote, this.localSize);
  bool get downloaded => localSize != null;
  bool get needsUpdate => remote != null && localSize != null && remote!.size != localSize;
  /// The size to show: the server's, or for a dictionary it no longer offers, the saved copy's.
  int get size => remote?.size ?? localSize!;

  /// Every language in [remote] or [local], sorted by code. A saved dictionary the server no longer
  /// offers is included, so that it can still be removed.
  static List<DictionaryStatus> merge(List<DictionaryInfo> remote, Map<String, int> local) {
    final offered = {for (final d in remote) d.lang: d};
    return [for (final lang in ({...offered.keys, ...local.keys}.toList()..sort()))
      DictionaryStatus(lang, offered[lang], local[lang])];
  }
}

const _folder = 'dictionaries';
/// In a browser, Dio's receive timeout also limits the whole transfer, and a large file takes long.
/// Native downloads don't need this: there it only limits the wait for the response to begin.
const _webDownloadTimeout = Duration(minutes: 20);
String _fileNameOf(String lang) => 'dict_$lang.json';
Future<Directory> _folderIn(String? root) async {
  final dir = Directory(p.join(root ?? (await getApplicationDocumentsDirectory()).path, _folder));
  await dir.create(recursive: true);
  return dir;
}

Map<String, dynamic> _parseDictionary(Uint8List bytes) {
  final json = jsonDecode(utf8.decode(bytes));
  if (json is! Map) throw const FormatException('The dictionary file is not valid');
  return Map<String, dynamic>.from(json);
}

/// Reads the saved dictionaries for use. The last one read stays in memory, because
/// a large file takes a while to parse (on a background isolate, except on web).
class SavedDictionaries {
  /// Replaceable for tests. [root] replaces the app's documents folder.
  static SavedDictionaries instance = SavedDictionaries();
  final String? root;
  SavedDictionaries({this.root});
  String? _lang;
  Future<WordDictionary>? _loaded;

  Future<bool> has(String lang) async => kIsWeb
    ? browser.hasDocument(_folder, _fileNameOf(lang))
    : File(p.join((await _folderIn(root)).path, _fileNameOf(lang))).exists();

  /// The dictionary of [lang]. Throws if it is not saved or can't be read (and tries again next time).
  Future<WordDictionary> load(String lang) {
    final loaded = _loaded;
    if (loaded != null && _lang == lang) return loaded;
    _lang = lang;
    final future = _read(lang);
    _loaded = future;
    future.then<void>((_) {}, onError: (Object _) { if (identical(_loaded, future)) { _loaded = null; _lang = null; } });
    return future;
  }

  Future<WordDictionary> _read(String lang) async {
    final bytes = kIsWeb ? await browser.readDocument(_folder, _fileNameOf(lang))
      : await File(p.join((await _folderIn(root)).path, _fileNameOf(lang))).readAsBytes();
    if (bytes == null) throw StateError('The dictionary "$lang" is not saved');
    return WordDictionary(await compute(_parseDictionary, bytes));
  }

  /// Must be called when the saved copy of [lang] has changed.
  void forget(String lang) { if (_lang == lang) { _lang = null; _loaded = null; } }
}

/// Dictionaries saved on this device, exactly as the server has them, so that their sizes compare.
/// Native: `<app documents>/dictionaries/dict_<lang>.json` ([root] replaces the app's documents folder).
/// Web: in the browser's IndexedDB, in the `dictionaries` folder of the document storage.
/// These server endpoints are public: no login token is sent, so a browser needs no CORS preflight
/// and the web app may run on any origin.
class Dictionaries {
  static final _language = RegExp(r'^[\w-]+$');
  static final _fileName = RegExp(r'^dict_([\w-]+)\.json$');
  final Api api;
  final String? root;
  Dictionaries(this.api, {this.root});

  Future<Directory> _dir() => _folderIn(root);

  /// What the server offers. A language code that couldn't be a file name is skipped.
  Future<List<DictionaryInfo>> available() async {
    final response = await api.dio.get<List<dynamic>>(api.url('/api/dictionaries'));
    return [for (final e in response.data!) DictionaryInfo.fromJson(Map<String, dynamic>.from(e as Map))]
      ..removeWhere((d) => !_language.hasMatch(d.lang));
  }

  /// The size in bytes of each saved dictionary, by language.
  Future<Map<String, int>> localSizes() async {
    final sizes = <String, int>{};
    void add(String name, int size) { final lang = _fileName.firstMatch(name)?.group(1); if (lang != null) sizes[lang] = size; }
    if (kIsWeb) {
      for (final (name, size) in await browser.listDocuments(_folder)) { add(name, size); }
    } else {
      await for (final e in (await _dir()).list()) {
        if (e is File) add(p.basename(e.path), await e.length());
      }
    }
    return sizes;
  }

  /// Downloads [dictionary] and saves it, replacing an earlier copy only once it has arrived whole.
  /// [onProgress] goes from 0 to 1.
  Future<void> download(DictionaryInfo dictionary, void Function(double) onProgress, {CancelToken? cancel}) async {
    void received(int count, int _) { if (dictionary.size > 0) onProgress((count / dictionary.size).clamp(0.0, 1.0)); }
    final url = api.url(dictionary.url), name = _fileNameOf(dictionary.lang);
    if (kIsWeb) {
      final response = await api.dio.get<List<int>>(url, cancelToken: cancel, onReceiveProgress: received,
        options: Options(responseType: ResponseType.bytes, receiveTimeout: _webDownloadTimeout));
      await browser.writeDocument(_folder, name, Uint8List.fromList(response.data!), 'application/json');
    } else {
      final target = p.join((await _dir()).path, name);
      final partial = File('$target.partial');
      try {
        await api.dio.download(url, partial.path, cancelToken: cancel, onReceiveProgress: received);
        await partial.rename(target);
      } catch (_) {
        try { await partial.delete(); } catch (_) {}
        rethrow;
      }
    }
    SavedDictionaries.instance.forget(dictionary.lang);
    onProgress(1);
  }

  /// Deletes the saved copy; nothing happens if there is none.
  Future<void> remove(String lang) async {
    SavedDictionaries.instance.forget(lang);
    if (kIsWeb) return browser.deleteDocument(_folder, _fileNameOf(lang));
    final file = File(p.join((await _dir()).path, _fileNameOf(lang)));
    if (await file.exists()) await file.delete();
  }
}
