import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:cross_file/cross_file.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'media_web.dart' as browser;

/// The three kinds of media, each kept on Google Drive in `/media/<folder>/<name>` with its icon in
/// `/media/<iconFolder>/<name>`.
enum MediaKind {
  picture('pictures', 'picture_icon', Icons.photo, 'image/jpeg'),
  video('videos', 'video_icon', Icons.videocam, 'video/mp4'),
  audio('audio', 'audio_icon', Icons.mic, 'audio/mp4');

  const MediaKind(this.folder, this.iconFolder, this.icon, this.defaultMimeType);
  final String folder, iconFolder;
  final IconData icon;
  final String defaultMimeType;
}

/// Longest side of an icon, in pixels.
const iconSize = 256;

/// A captured, recorded or downloaded media file kept only temporarily on this device: a file in the
/// app's temporary folder, or on web the bytes in memory. [MediaTemp.clearAll] removes them all.
class LocalMedia {
  LocalMedia._(this.kind, this.mimeType, {this.path, Uint8List? bytes}) : _bytes = bytes;
  final MediaKind kind;
  final String mimeType;
  /// The file (not on web).
  final String? path;
  Uint8List? _bytes;
  String? _objectUrl;
  bool _deleted = false;
  bool get deleted => _deleted;

  Future<Uint8List> readBytes() async => _bytes ?? await File(path!).readAsBytes();
  Future<int> length() async => _bytes?.length ?? await File(path!).length();

  /// What a player can open: the file's path, or on web a `blob:` URL (released by [delete]).
  String get source => path ?? (_objectUrl ??= browser.createObjectUrl(_bytes!, mimeType));

  Future<void> delete() async {
    if (_deleted) return;
    _deleted = true;
    MediaTemp._items.remove(this);
    final url = _objectUrl; _objectUrl = null; _bytes = null;
    if (url != null) browser.revokeObjectUrl(url);
    final file = path;
    if (file != null) { try { await File(file).delete(); } catch (_) {} }
  }
}

/// Where Media keeps its temporary files: `<temp>/norsk_media` (in memory on web).
class MediaTemp {
  static final _items = <LocalMedia>{};
  /// Files downloaded for viewing, by `<kind>/<name>`, so viewing again needs no new download.
  static final _viewed = <String, LocalMedia>{};

  static Future<Directory> _dir() async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'norsk_media'));
    await dir.create(recursive: true);
    return dir;
  }

  /// A new, unused path for a file with [extension] (e.g. `.m4a`). Not on web.
  static Future<String> newPath(String extension) async =>
    p.join((await _dir()).path, '${DateTime.now().microsecondsSinceEpoch}$extension');

  static LocalMedia _add(LocalMedia m) { _items.add(m); return m; }

  /// Takes over a file from the camera or the recorder: on web its bytes are read into memory and the
  /// browser's copy is released; elsewhere the file is moved into the temporary folder.
  static Future<LocalMedia> adopt(XFile file, MediaKind kind, {String? mimeType}) async {
    final type = mimeType ?? file.mimeType ?? mimeTypeFor(file.name.isEmpty ? file.path : file.name, kind);
    if (kIsWeb) {
      final bytes = await file.readAsBytes();
      browser.revokeObjectUrl(file.path);
      return _add(LocalMedia._(kind, type, bytes: bytes));
    }
    final dir = await _dir();
    var path = file.path;
    if (!p.isWithin(dir.path, path)) {
      final target = p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}${p.extension(path)}');
      try { await File(path).rename(target); }
      catch (_) { await File(path).copy(target); try { await File(path).delete(); } catch (_) {} }
      path = target;
    }
    return _add(LocalMedia._(kind, type, path: path));
  }

  /// The copy of [kind] [name] downloaded earlier for viewing, if it is still here.
  static LocalMedia? viewed(MediaKind kind, String name) {
    final m = _viewed['${kind.name}/$name'];
    return m == null || m.deleted ? null : m;
  }

  /// Keeps a downloaded copy for viewing: written to a file, or on web kept in memory.
  static Future<LocalMedia> saveViewed(MediaKind kind, String name, String mimeType, {Uint8List? bytes, String? path}) async {
    final m = _add(LocalMedia._(kind, mimeType, path: path, bytes: bytes));
    await _viewed.remove('${kind.name}/$name')?.delete();
    _viewed['${kind.name}/$name'] = m;
    return m;
  }

  static Future<void> forgetViewed(MediaKind kind, String name) async => _viewed.remove('${kind.name}/$name')?.delete();

  /// Removes every temporary Media file (called when leaving Media).
  static Future<void> clearAll() async {
    for (final m in [..._items]) { await m.delete(); }
    _viewed.clear();
    if (!kIsWeb) {
      try { final dir = Directory(p.join((await getTemporaryDirectory()).path, 'norsk_media')); if (await dir.exists()) await dir.delete(recursive: true); }
      catch (_) {}
    }
  }
}

/// The media type of [fileName] from its extension, or [kind]'s default.
String mimeTypeFor(String fileName, MediaKind kind) => switch (p.extension(fileName).toLowerCase()) {
  '.jpg' || '.jpeg' => 'image/jpeg', '.png' => 'image/png', '.heic' => 'image/heic', '.webp' => 'image/webp',
  '.mp4' => 'video/mp4', '.mov' => 'video/quicktime', '.webm' => kind == MediaKind.audio ? 'audio/webm' : 'video/webm',
  '.m4a' || '.aac' => 'audio/mp4', '.ogg' || '.opus' => 'audio/ogg', '.wav' => 'audio/wav', '.mp3' => 'audio/mpeg',
  _ => kind.defaultMimeType,
};

/// An icon for [media]: a small copy of a picture, a frame of a video, or for audio (and whenever a
/// video frame can't be had) a drawn icon with the duration. Returns the bytes and their media type.
Future<(Uint8List, String)> makeIcon(LocalMedia media, {Duration? duration}) async {
  try {
    switch (media.kind) {
      case MediaKind.picture:
        return (await _shrink(await media.readBytes()), 'image/png');
      case MediaKind.video:
        final frame = kIsWeb ? await browser.videoFrameJpeg(media.source, iconSize)
          : await FcNativeVideoThumbnail().saveThumbnailToBytes(srcFile: media.path!, width: iconSize, height: iconSize, format: 'jpeg', quality: 80);
        if (frame != null && frame.isNotEmpty) return (frame, 'image/jpeg');
      case MediaKind.audio:
        break;
    }
  } catch (_) {}
  return (await drawnIcon(media.kind, duration), 'image/png');
}

/// [bytes] (an image) scaled down to at most [iconSize] pixels on its longer side, as PNG.
Future<Uint8List> _shrink(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodecWithSize(await ui.ImmutableBuffer.fromUint8List(bytes), getTargetSize: (w, h) {
    final scale = math.min(1.0, iconSize / math.max(w, h));
    return ui.TargetImageSize(width: math.max(1, (w * scale).round()), height: math.max(1, (h * scale).round()));
  });
  final image = (await codec.getNextFrame()).image;
  try { return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List(); }
  finally { image.dispose(); codec.dispose(); }
}

/// A square icon with [kind]'s symbol and, when known, [duration] (e.g. "1:05").
Future<Uint8List> drawnIcon(MediaKind kind, Duration? duration) async {
  const size = iconSize * 1.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, size, size), const Radius.circular(32)), Paint()..color = const Color(0xff315f72));
  final glyph = TextPainter(textDirection: TextDirection.ltr, text: TextSpan(text: String.fromCharCode(kind.icon.codePoint),
    style: TextStyle(fontFamily: kind.icon.fontFamily, package: kind.icon.fontPackage, fontSize: size * 0.5, color: Colors.white)))..layout();
  final hasTime = duration != null && duration > Duration.zero;
  glyph.paint(canvas, Offset((size - glyph.width) / 2, (size - glyph.height) / 2 - (hasTime ? size * 0.1 : 0)));
  if (hasTime) {
    final time = TextPainter(textDirection: TextDirection.ltr, text: TextSpan(text: formatDuration(duration),
      style: const TextStyle(fontSize: size * 0.14, color: Colors.white, fontWeight: FontWeight.w600)))..layout();
    time.paint(canvas, Offset((size - time.width) / 2, size * 0.74));
  }
  final image = await recorder.endRecording().toImage(iconSize, iconSize);
  try { return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List(); }
  finally { image.dispose(); }
}

/// "m:ss", or "h:mm:ss" from an hour on.
String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}
