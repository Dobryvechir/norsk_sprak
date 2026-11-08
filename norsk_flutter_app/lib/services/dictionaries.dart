import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'api.dart';
import 'document_web.dart' as browser;

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

/// Dictionaries saved on this device, exactly as the server has them, so that their sizes compare.
/// Native: `<app documents>/dictionaries/dict_<lang>.json` ([root] replaces the app's documents folder).
/// Web: in the browser's IndexedDB, in the `dictionaries` folder of the document storage.
/// These server endpoints are public: no login token is sent, so a browser needs no CORS preflight
/// and the web app may run on any origin.
class Dictionaries {
  static const _folder = 'dictionaries';
  static final _language = RegExp(r'^[\w-]+$');
  static final _fileName = RegExp(r'^dict_([\w-]+)\.json$');
  final Api api;
  final String? root;
  Dictionaries(this.api, {this.root});

  static String _name(String lang) => 'dict_$lang.json';

  Future<Directory> _dir() async {
    final dir = Directory(p.join(root ?? (await getApplicationDocumentsDirectory()).path, _folder));
    await dir.create(recursive: true);
    return dir;
  }

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
    final url = api.url(dictionary.url), name = _name(dictionary.lang);
    if (kIsWeb) {
      final response = await api.dio.get<List<int>>(url, cancelToken: cancel, onReceiveProgress: received,
        options: Options(responseType: ResponseType.bytes));
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
    onProgress(1);
  }

  /// Deletes the saved copy; nothing happens if there is none.
  Future<void> remove(String lang) async {
    if (kIsWeb) return browser.deleteDocument(_folder, _name(lang));
    final file = File(p.join((await _dir()).path, _name(lang)));
    if (await file.exists()) await file.delete();
  }
}
