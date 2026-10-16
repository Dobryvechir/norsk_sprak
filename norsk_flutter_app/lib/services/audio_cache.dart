import 'dart:io';
import 'package:dio/dio.dart' show Headers;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'api.dart';

/// Cached audio is stored as `<id>.<ext>` with the real extension, because iOS (AVPlayer)
/// picks the decoder for local files from the extension.
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
  /// The downloaded file for [id], or null if it has not been downloaded yet.
  Future<File?> cached(String id) async {
    await for (final e in (await _dir()).list()) {
      if (e is! File || p.basenameWithoutExtension(e.path) != id) continue;
      // Files from older app versions were saved as `<id>.audio`, which iOS cannot play: drop them.
      if (p.extension(e.path) == '.audio' || await e.length() == 0) { await e.delete(); continue; }
      return e;
    }
    return null;
  }
  Future<File> obtain(String id, void Function(double) onProgress) async {
    final existing = await cached(id);
    if (existing != null) { onProgress(1); return existing; }
    final tmp = File(p.join((await _dir()).path, '$id.download.partial'));
    try {
      final headers = await api.downloadAudio(id, tmp.path, onProgress);
      return tmp.rename(p.join(tmp.parent.path, '$id.${_extensionFrom(headers)}'));
    } catch (_) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }
  Future<void> clear(String id) async {
    await for (final e in (await _dir()).list()) {
      if (e is File && p.basenameWithoutExtension(e.path) == id) await e.delete();
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
