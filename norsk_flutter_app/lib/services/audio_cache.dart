import 'dart:io';
import 'package:dio/dio.dart' show Headers;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/entities.dart';
import 'api.dart';

/// Cached audio is stored as `<recording id>_<language>_<upload time>.<ext>` (chapters: `chapter-<id>_…`), one file per
/// language. The upload time makes a replaced audio get a new name, so a stale copy is never played.
/// The real extension is kept because iOS (AVPlayer) picks the decoder for local files from it.
class AudioCache {
  static const _extensions = {'mp3','m4a','wav','ogg','opus','mp4','aac','flac'};
  static const _mimeExtensions = {
    'audio/mpeg': 'mp3', 'audio/mp3': 'mp3', 'audio/mp4': 'm4a', 'audio/x-m4a': 'm4a', 'audio/m4a': 'm4a',
    'video/mp4': 'mp4', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/wave': 'wav', 'audio/ogg': 'ogg',
    'audio/opus': 'opus', 'audio/aac': 'aac', 'audio/x-aac': 'aac', 'audio/flac': 'flac', 'audio/x-flac': 'flac',
  };
  final Api api;
  AudioCache(this.api);
  Future<Directory> _dir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'audio_cache'));
    await dir.create(recursive: true);
    return dir;
  }
  /// Recordings and chapters have separate ID spaces, so chapters get a prefix.
  static String cacheId(Recording r) => r.isChapter ? 'chapter-${r.id}' : r.id;
  static String _name(Recording r, String language) =>
    '${cacheId(r)}_${language}_${(r.audio[language]?.createdAt ?? '').replaceAll(RegExp(r'\D'), '')}';
  /// The downloaded file for [language]'s audio of [r], or null if it has not been downloaded yet.
  /// Older copies of the same language (from before the audio was replaced) are deleted.
  Future<File?> cached(Recording r, String language) async {
    final name = _name(r, language);
    File? found;
    await for (final e in (await _dir()).list()) {
      if (e is! File) continue;
      final base = p.basenameWithoutExtension(e.path);
      if (base == name && p.extension(e.path) != '.partial' && await e.length() > 0) { found = e; }
      else if (base.startsWith('${cacheId(r)}_${language}_') && !base.endsWith('.download')) { await e.delete(); }
    }
    return found;
  }
  Future<File> obtain(Recording r, String language, void Function(double) onProgress) async {
    final existing = await cached(r, language);
    if (existing != null) { onProgress(1); return existing; }
    final name = _name(r, language);
    final tmp = File(p.join((await _dir()).path, '$name.download.partial'));
    try {
      final headers = await api.downloadAudio(r, language, tmp.path, onProgress);
      return await tmp.rename(p.join(tmp.parent.path, '$name.${_extensionFrom(headers)}'));
    } catch (_) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }
  /// Deletes every cached audio of the recording (or chapter: pass [cacheId]), in all languages
  /// (and files from older app versions).
  Future<void> clear(String recordingId) async {
    await for (final e in (await _dir()).list()) {
      final base = p.basenameWithoutExtension(e.path);
      if (e is File && (base == recordingId || base.startsWith('${recordingId}_'))) await e.delete();
    }
  }
  /// Extension from the server's Content-Disposition filename, then Content-Type, else mp3.
  static String _extensionFrom(Headers headers) {
    final disposition = headers.value('content-disposition') ?? '';
    final encoded = RegExp(r"filename\*=[^']*''([^;]+)").firstMatch(disposition)?.group(1);
    final name = encoded != null ? Uri.decodeComponent(encoded.trim())
        : RegExp(r'filename="?([^";]+)').firstMatch(disposition)?.group(1);
    if (name != null) {
      final ext = p.extension(name.trim()).replaceFirst('.', '').toLowerCase();
      if (_extensions.contains(ext)) return ext;
    }
    final mime = headers.value('content-type')?.split(';').first.trim().toLowerCase();
    return _mimeExtensions[mime] ?? 'mp3';
  }
}
