import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/entities.dart';
import 'api.dart';
import 'audio_cache.dart';
import 'web_store.dart' as web_store;

/// A chapter saved on this device, with the names of its section (for the list of saved chapters).
class SavedChapter {
  final Recording chapter;
  final Map<String, String> sectionNames;
  const SavedChapter(this.chapter, this.sectionNames);
  /// The section's name in [language] when it has one (else as [Book.displayName] picks), or ''.
  String sectionTitle(String language) =>
    sectionNames.isEmpty ? '' : Book('', sectionNames, '', const [], const [], '').displayName(language);
  /// The section name, a space and the chapter name, e.g. "Matthew 1".
  String title(String language) {
    final section = sectionTitle(language);
    return section.isEmpty ? chapter.name : '$section ${chapter.name}';
  }
}

/// Book chapters saved on this device for offline use: the whole chapter (texts and timings in every
/// language) as JSON and every language's audio. A saved audio's `local_file` is set in the JSON.
/// Native: `offline_chapters/<id>.json` with the audio in `offline_chapters/<id>/<language>.<ext>`
/// (`local_file` is that name, relative to the folder, because the app's folder can move on iOS updates).
/// Web: both in the browser's IndexedDB (see web_store.dart; `local_file` is then just the language).
/// Chapters saved by older web versions are in local storage under `offline_chapter_<id>`, without audio:
/// they are still read (and played from the audio's `url`), and removed like the others.
/// The audio is downloaded from its `url` when it has one, else from the server's audio endpoint.
/// The JSON is written last, so a chapter counts as saved only once everything is.
class OfflineChapters {
  static const _legacyPrefix = 'offline_chapter_';
  /// Extra field in the saved JSON: the chapter's section `{"id", "name": {language: name}}`.
  static const _sectionField = 'saved_section';
  final Api api;
  OfflineChapters(this.api);

  static String _safe(String id) => id.replaceAll(RegExp(r'[^\w-]'), '_');
  static Future<Directory> _root() async {
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'offline_chapters'));
    await dir.create(recursive: true);
    return dir;
  }
  static Future<File> _jsonFile(String id) async => File(p.join((await _root()).path, '${_safe(id)}.json'));
  static Future<Directory> _audioDir(String id) async => Directory(p.join((await _root()).path, _safe(id)));

  /// Which of [ids] are saved.
  Future<Set<String>> saved(Iterable<String> ids) async {
    if (kIsWeb) {
      final stored = {...await web_store.chapterIds()};
      final prefs = await SharedPreferences.getInstance();
      return {for (final id in ids) if (stored.contains(id) || prefs.containsKey('$_legacyPrefix$id')) id};
    }
    return {for (final id in ids) if (await (await _jsonFile(id)).exists()) id};
  }

  Future<String?> _json(String id) async {
    if (kIsWeb) return await web_store.getChapter(id) ?? (await SharedPreferences.getInstance()).getString('$_legacyPrefix$id');
    final f = await _jsonFile(id);
    return await f.exists() ? await f.readAsString() : null;
  }
  static Map<String, dynamic> _decode(String json) => Map<String, dynamic>.from(jsonDecode(json) as Map);

  /// The saved chapter, or null if it is not saved.
  Future<Recording?> load(String id) async {
    final json = await _json(id);
    return json == null ? null : Recording.fromJson(_decode(json));
  }

  /// Every saved chapter, sorted by section name (in [language]), then by chapter name (numbers by value).
  /// A chapter whose saved copy can't be read is left out.
  Future<List<SavedChapter>> all(String language) async {
    final List<String> ids;
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      ids = {...await web_store.chapterIds(),
        for (final k in prefs.getKeys()) if (k.startsWith(_legacyPrefix)) k.substring(_legacyPrefix.length)}.toList();
    } else {
      ids = [];
      await for (final e in (await _root()).list()) {
        if (e is File && e.path.endsWith('.json')) {
          try { ids.add('${_decode(await e.readAsString())['id']}'); } catch (_) {}
        }
      }
    }
    final result = <SavedChapter>[];
    for (final id in ids) {
      try {
        final json = await _json(id);
        if (json == null) continue;
        final j = _decode(json);
        final section = j[_sectionField] is Map ? Map<String, dynamic>.from(j[_sectionField] as Map) : const <String, dynamic>{};
        final names = {for (final e in ((section['name'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
        result.add(SavedChapter(Recording.fromJson(j), names));
      } catch (_) {}
    }
    return result..sort((a, b) {
      final bySection = a.sectionTitle(language).toLowerCase().compareTo(b.sectionTitle(language).toLowerCase());
      return bySection != 0 ? bySection : naturalCompare(a.chapter.name, b.chapter.name);
    });
  }

  /// The saved audio file of [language] in chapter [r], or null (always on web: see [webAudioUrl]).
  Future<File?> audioFile(Recording r, String language) async {
    final name = r.audio[language]?.localFile;
    if (kIsWeb || name == null) return null;
    final f = File(p.join((await _audioDir(r.id)).path, name));
    return await f.exists() ? f : null;
  }

  /// On web: a `blob:` URL of the saved audio of [language] in chapter [r], or null if it is not saved.
  /// Release it with [releaseWebAudioUrl] when done.
  Future<String?> webAudioUrl(Recording r, String language) async {
    if (!kIsWeb || r.audio[language]?.localFile == null) return null;
    return web_store.audioObjectUrl(r.id, language);
  }
  static void releaseWebAudioUrl(String url) => web_store.revokeObjectUrl(url);

  /// Deletes the saved chapter and its audio files; nothing happens if it is not saved.
  Future<void> remove(String id) async {
    if (kIsWeb) {
      await (await SharedPreferences.getInstance()).remove('$_legacyPrefix$id');
      await web_store.removeChapter(id);
      return;
    }
    // The JSON first, so a half-removed chapter no longer counts as saved.
    final f = await _jsonFile(id);
    if (await f.exists()) await f.delete();
    final dir = await _audioDir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Fetches the chapter with all its content and every language's audio, and saves them.
  /// [section] (the chapter's section) is saved with it, for the list of saved chapters.
  /// [onProgress] goes from 0 to 1 over all the audio files.
  Future<Recording> download(String id, void Function(double) onProgress, {Section? section}) async {
    var chapter = await api.chapter(id);
    if (chapter.audio.isNotEmpty) {
      final languages = chapter.audio.keys.toList();
      final audio = {...chapter.audio};
      void progress(int i, double v) => onProgress((i + v) / languages.length);
      if (kIsWeb) {
        await web_store.removeAudio(id);
        try {
          for (var i = 0; i < languages.length; i++) {
            final language = languages[i];
            final (bytes, type) = await api.audioBytes(chapter, language, (v) => progress(i, v));
            await web_store.putAudio(id, language, bytes, type ?? 'audio/mpeg');
            audio[language] = audio[language]!.withLocalFile(language);
          }
        } catch (_) {
          await web_store.removeAudio(id).catchError((_) {});
          rethrow;
        }
      } else {
        final dir = await _audioDir(id);
        if (await dir.exists()) await dir.delete(recursive: true);
        await dir.create(recursive: true);
        try {
          for (var i = 0; i < languages.length; i++) {
            final language = languages[i];
            final tmp = File(p.join(dir.path, '$language.partial'));
            final headers = await api.downloadAudio(chapter, language, tmp.path, (v) => progress(i, v));
            final name = '$language.${AudioCache.extensionFrom(headers)}';
            await tmp.rename(p.join(dir.path, name));
            audio[language] = audio[language]!.withLocalFile(name);
          }
        } catch (_) {
          if (await dir.exists()) await dir.delete(recursive: true);
          rethrow;
        }
      }
      chapter = chapter.withAudio(audio);
    }
    final json = jsonEncode({...chapter.toJson(),
      if (section != null) _sectionField: {'id': section.id, 'name': section.names}});
    if (kIsWeb) {
      await web_store.putChapter(id, json);
      await (await SharedPreferences.getInstance()).remove('$_legacyPrefix$id');
      await web_store.requestPersistence();
    } else {
      final f = await _jsonFile(id);
      final tmp = File('${f.path}.partial');
      await tmp.writeAsString(json);
      await tmp.rename(f.path);
    }
    onProgress(1);
    return chapter;
  }
}

/// Compares names so that numbers sort by value: "2" before "10", "Salme 2" before "Salme 10".
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final x = re.allMatches(a.toLowerCase()).toList(), y = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final s = x[i].group(0)!, t = y[i].group(0)!;
    final m = int.tryParse(s), n = int.tryParse(t);
    final c = m != null && n != null ? m.compareTo(n) : s.compareTo(t);
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}
