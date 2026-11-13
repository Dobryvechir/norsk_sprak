import 'dart:typed_data';
import 'package:dio/dio.dart' show ProgressCallback;
import 'package:path/path.dart' as p;
import '../l10n/l10n.dart';
import 'google_drive.dart';
import 'media_store.dart' show shrinkImage;

/// What a place that takes files accepts: their extensions (lower case, with the dot), or any file.
class ImportTarget {
  const ImportTarget(this.extensions);
  /// Any file at all (Chat): Google Docs, Sheets etc. are still turned into ordinary files.
  const ImportTarget.any() : extensions = null;
  final List<String>? extensions;

  static const pictures = ImportTarget(['.png', '.jpg', '.jpeg', '.gif']);
  static const audio = ImportTarget(['.mp3', '.m4a', '.wav', '.ogg', '.opus', '.mp4', '.aac', '.flac']);

  bool accepts(String extension) => extensions == null || extensions!.contains(extension);
}

/// How a Drive file becomes a file of the expected type.
enum ImportMethod {
  /// Its content as it is (only its name may get the right extension).
  download,
  /// A Google Docs, Sheets, Slides or Drawings file, exported by Drive.
  export,
  /// An Office, OpenDocument, CSV or text file, first converted by Drive into a Google file (a
  /// temporary copy, deleted afterwards), and that exported.
  convert,
  /// A picture in a format not accepted here (WebP, HEIC, BMP, TIFF, SVG, …), turned into PNG on this
  /// device, or from Drive's own preview of it when this device can't read the format.
  picture,
}

/// The way to get a Drive file as one the target accepts: [name] and [mimeType] are the result's.
class ImportPlan {
  const ImportPlan(this.method, this.name, this.mimeType, {this.googleType});
  final ImportMethod method;
  final String name, mimeType;
  /// The Google type that [ImportMethod.export] exports from, or [ImportMethod.convert] converts to.
  final String? googleType;
  String get extension => p.extension(name).toLowerCase();
  @override String toString() => '$method $name $mimeType';
}

/// A file got from Drive.
class ImportedFile {
  const ImportedFile(this.name, this.mimeType, this.bytes);
  final String name, mimeType;
  final Uint8List bytes;
}

const _google = 'application/vnd.google-apps.';
const googleDocument = '${_google}document', googleSpreadsheet = '${_google}spreadsheet',
  googlePresentation = '${_google}presentation', googleDrawing = '${_google}drawing';

const _pdf = 'application/pdf';
const _xlsx = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const _docx = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const _pptx = 'application/vnd.openxmlformats-officedocument.presentationml.presentation';

/// The usual extension for each media type, with the other names the same type goes by (as reported by
/// Drive, browsers, phones and older programs). Extensions are lower case, with the dot.
const _types = <String, (String, List<String>)>{
  // Pictures
  'image/jpeg': ('.jpg', ['image/jpg', 'image/pjpeg', 'image/jpe', 'image/x-citrix-jpeg']),
  'image/png': ('.png', ['image/x-png', 'image/apng', 'image/vnd.mozilla.apng', 'image/x-citrix-png']),
  'image/gif': ('.gif', []),
  'image/webp': ('.webp', ['image/x-webp']),
  'image/bmp': ('.bmp', ['image/x-bmp', 'image/x-ms-bmp', 'image/x-windows-bmp']),
  'image/heic': ('.heic', ['image/heif', 'image/heic-sequence', 'image/heif-sequence']),
  'image/avif': ('.avif', []),
  'image/tiff': ('.tiff', ['image/x-tiff', 'image/tif']),
  'image/svg+xml': ('.svg', []),
  'image/x-icon': ('.ico', ['image/vnd.microsoft.icon', 'image/ico']),
  'image/vnd.wap.wbmp': ('.wbmp', []),
  'image/jxl': ('.jxl', []),
  'image/x-adobe-dng': ('.dng', ['image/dng']),
  'image/x-canon-cr2': ('.cr2', []),
  'image/x-nikon-nef': ('.nef', []),
  'image/x-sony-arw': ('.arw', []),
  'image/vnd.adobe.photoshop': ('.psd', ['image/x-photoshop', 'application/x-photoshop', 'image/psd']),
  // PDF and spreadsheets, documents, presentations
  _pdf: ('.pdf', ['application/x-pdf', 'application/acrobat', 'applications/vnd.pdf', 'text/pdf', 'text/x-pdf']),
  _xlsx: ('.xlsx', []),
  'application/vnd.ms-excel.sheet.macroenabled.12': ('.xlsm', []),
  'application/vnd.openxmlformats-officedocument.spreadsheetml.template': ('.xltx', []),
  'application/vnd.ms-excel': ('.xls', ['application/msexcel', 'application/x-msexcel', 'application/x-ms-excel',
    'application/x-excel', 'application/x-dos_ms_excel', 'application/xls', 'application/x-xls']),
  'application/vnd.oasis.opendocument.spreadsheet': ('.ods', []),
  'text/csv': ('.csv', ['text/comma-separated-values', 'text/x-csv', 'application/csv', 'text/x-comma-separated-values']),
  'text/tab-separated-values': ('.tsv', []),
  _docx: ('.docx', []),
  'application/vnd.openxmlformats-officedocument.wordprocessingml.template': ('.dotx', []),
  'application/msword': ('.doc', ['application/doc', 'application/ms-doc']),
  'application/vnd.oasis.opendocument.text': ('.odt', []),
  'application/rtf': ('.rtf', ['text/rtf', 'application/x-rtf', 'text/richtext']),
  'text/plain': ('.txt', []),
  'text/markdown': ('.md', ['text/x-markdown']),
  'text/html': ('.html', ['application/xhtml+xml']),
  'application/epub+zip': ('.epub', []),
  _pptx: ('.pptx', []),
  'application/vnd.openxmlformats-officedocument.presentationml.slideshow': ('.ppsx', []),
  'application/vnd.ms-powerpoint': ('.ppt', ['application/mspowerpoint', 'application/x-mspowerpoint']),
  'application/vnd.oasis.opendocument.presentation': ('.odp', []),
  // Audio
  'audio/mpeg': ('.mp3', ['audio/mp3', 'audio/mpeg3', 'audio/x-mpeg-3', 'audio/x-mp3', 'audio/x-mpeg', 'audio/mpg']),
  'audio/mp4': ('.m4a', ['audio/x-m4a', 'audio/m4a', 'audio/x-mp4', 'audio/mp4a-latm', 'audio/x-m4b', 'audio/m4b']),
  'audio/aac': ('.aac', ['audio/x-aac', 'audio/aacp', 'audio/x-hx-aac-adts', 'audio/vnd.dlna.adts']),
  'audio/wav': ('.wav', ['audio/x-wav', 'audio/wave', 'audio/vnd.wave', 'audio/x-pn-wav']),
  'audio/ogg': ('.ogg', ['audio/vorbis', 'audio/x-vorbis+ogg', 'audio/x-ogg', 'application/ogg', 'audio/vorbis-config']),
  'audio/opus': ('.opus', ['audio/x-opus+ogg', 'audio/x-opus']),
  'audio/flac': ('.flac', ['audio/x-flac']),
  'audio/webm': ('.weba', []),
  'audio/amr': ('.amr', ['audio/amr-wb']),
  'audio/3gpp': ('.3gp', ['audio/3gpp2']),
  'audio/x-ms-wma': ('.wma', []),
  'audio/aiff': ('.aiff', ['audio/x-aiff']),
  'audio/midi': ('.mid', ['audio/x-midi']),
  // Video
  'video/mp4': ('.mp4', ['video/mpeg4', 'video/x-mp4', 'application/mp4']),
  'video/x-m4v': ('.m4v', []),
  'video/quicktime': ('.mov', ['video/x-quicktime']),
  'video/webm': ('.webm', []),
  'video/x-matroska': ('.mkv', ['video/mkv']),
  'video/x-msvideo': ('.avi', ['video/avi', 'video/msvideo', 'video/vnd.avi']),
  'video/3gpp': ('.3gp', []),
  'video/3gpp2': ('.3g2', []),
  'video/mpeg': ('.mpeg', ['video/x-mpeg']),
  'video/x-ms-wmv': ('.wmv', []),
  'video/x-flv': ('.flv', []),
  'video/mp2t': ('.ts', []),
  'video/ogg': ('.ogv', []),
};

/// Extensions that are other names for an accepted one (the file is renamed, not changed).
const _sameAs = <String, String>{
  '.jpeg': '.jpg', '.jpe': '.jpg', '.jfif': '.jpg', '.pjpeg': '.jpg', '.pjp': '.jpg',
  '.tif': '.tiff', '.heif': '.heic', '.htm': '.html', '.mpga': '.mp3', '.m4b': '.m4a',
  '.oga': '.ogg', '.wave': '.wav', '.m4v': '.mp4', '.mpg': '.mpeg', '.markdown': '.md',
};

/// The canonical name of [mimeType] (lower case, without parameters such as `; charset=…`).
String canonicalMimeType(String mimeType) {
  final type = mimeType.split(';').first.trim().toLowerCase();
  if (_types.containsKey(type)) return type;
  for (final e in _types.entries) { if (e.value.$2.contains(type)) return e.key; }
  return type;
}

/// The usual extension for [mimeType], or null when it is unknown.
String? extensionForMimeType(String mimeType) => _types[canonicalMimeType(mimeType)]?.$1;

/// The canonical media type of a file named [fileName], or null when its extension is unknown.
String? mimeTypeForExtension(String fileName) {
  var ext = p.extension(fileName).toLowerCase();
  for (final e in _types.entries) { if (e.value.$1 == ext) return e.key; }
  ext = _sameAs[ext] ?? ext;
  for (final e in _types.entries) { if (e.value.$1 == ext) return e.key; }
  return null;
}

/// What Drive can export each Google type as, the most useful first: (media type, extension).
const _exports = <String, List<(String, String)>>{
  googleDocument: [(_pdf, '.pdf'), (_docx, '.docx'), ('application/vnd.oasis.opendocument.text', '.odt'),
    ('application/rtf', '.rtf'), ('text/plain', '.txt'), ('text/markdown', '.md'), ('application/epub+zip', '.epub')],
  googleSpreadsheet: [(_xlsx, '.xlsx'), (_pdf, '.pdf'), ('application/vnd.oasis.opendocument.spreadsheet', '.ods'),
    ('text/csv', '.csv'), ('text/tab-separated-values', '.tsv')],
  googlePresentation: [(_pdf, '.pdf'), (_pptx, '.pptx'), ('application/vnd.oasis.opendocument.presentation', '.odp'),
    ('image/png', '.png'), ('image/jpeg', '.jpg'), ('text/plain', '.txt')],
  googleDrawing: [('image/png', '.png'), ('image/jpeg', '.jpg'), (_pdf, '.pdf'), ('image/svg+xml', '.svg')],
  '${_google}jam': [(_pdf, '.pdf')],
};

/// Files that Drive can convert into a Google type (by their canonical media type).
const _convertible = <String, String>{
  'application/vnd.ms-excel': googleSpreadsheet,
  'application/vnd.ms-excel.sheet.macroenabled.12': googleSpreadsheet,
  'application/vnd.openxmlformats-officedocument.spreadsheetml.template': googleSpreadsheet,
  'application/vnd.oasis.opendocument.spreadsheet': googleSpreadsheet,
  'text/csv': googleSpreadsheet,
  'text/tab-separated-values': googleSpreadsheet,
  _xlsx: googleSpreadsheet,
  _docx: googleDocument,
  'application/vnd.openxmlformats-officedocument.wordprocessingml.template': googleDocument,
  'application/msword': googleDocument,
  'application/vnd.oasis.opendocument.text': googleDocument,
  'application/rtf': googleDocument,
  'text/plain': googleDocument,
  'text/markdown': googleDocument,
  'text/html': googleDocument,
  _pptx: googlePresentation,
  'application/vnd.openxmlformats-officedocument.presentationml.slideshow': googlePresentation,
  'application/vnd.ms-powerpoint': googlePresentation,
  'application/vnd.oasis.opendocument.presentation': googlePresentation,
};

String _withExtension(String name, String extension) {
  final base = p.withoutExtension(name).trim();
  return '${base.isEmpty ? 'file' : base}$extension';
}

/// How [file] can be had as a file [target] accepts, or null when it can't (folders, Forms, Sites,
/// or audio and video in a format not accepted here: those can't be converted on Drive or this device).
ImportPlan? planImport(DriveFile file, ImportTarget target) {
  final type = canonicalMimeType(file.mimeType);
  if (type.startsWith(_google)) {
    for (final (mime, ext) in _exports[type] ?? const <(String, String)>[]) {
      if (target.accepts(ext)) return ImportPlan(ImportMethod.export, _withExtension(file.name, ext), mime, googleType: type);
    }
    return null;
  }
  // The file's own extension when it fits the media type (or Drive doesn't know the type), else the type's.
  final nameExt = p.extension(file.name).toLowerCase(), nameType = mimeTypeForExtension(file.name);
  final known = _types.containsKey(type);
  // Audio and video types are loose (an .opus is often reported as audio/ogg, an .m4a as video/mp4):
  // between those, the name's extension is trusted.
  bool av(String t) => t.startsWith('audio/') || t.startsWith('video/') || t == 'application/ogg';
  // So is the name of a file Drive only knows as plain text or bytes (a .csv, an .xlsx uploaded oddly).
  final generic = type == 'text/plain' || type.endsWith('octet-stream') || type.contains('download');
  final trustName = !known || nameType == type || (nameType != null && (generic || (av(nameType) && av(type))));
  final mime = known && !(trustName && nameType != null) ? type : nameType ?? type;
  final ext = trustName ? nameExt : _types[type]!.$1;
  if (ext.isNotEmpty) {
    if (target.extensions == null) {
      return ImportPlan(ImportMethod.download, nameExt == ext || _sameAs[nameExt] == ext ? file.name : _withExtension(file.name, ext), mime);
    }
    for (final candidate in {ext, _sameAs[ext]}.whereType<String>()) {
      if (target.accepts(candidate)) {
        return ImportPlan(ImportMethod.download, nameExt == candidate ? file.name : _withExtension(file.name, candidate), mime);
      }
    }
  } else if (target.extensions == null) {
    return ImportPlan(ImportMethod.download, file.name, mime.isEmpty ? 'application/octet-stream' : mime);
  }
  if (mime.startsWith('image/') && target.accepts('.png')) {
    return ImportPlan(ImportMethod.picture, _withExtension(file.name, '.png'), 'image/png');
  }
  final google = _convertible[mime];
  if (google != null) {
    for (final (exportType, exportExt) in _exports[google]!) {
      if (target.accepts(exportExt) && exportExt != ext) {
        return ImportPlan(ImportMethod.convert, _withExtension(file.name, exportExt), exportType, googleType: google);
      }
    }
  }
  return null;
}

/// Gets files from the user's Google Drive as the files a place in the app accepts (see [planImport]).
class DriveImporter {
  DriveImporter(this.drive);
  final GoogleDrive drive;

  /// The longest side of a picture made from Drive's preview, when this device can't read the format.
  static const previewSize = 2048;

  /// [file] as planned by [plan].
  Future<ImportedFile> fetch(DriveFile file, ImportPlan plan, {ProgressCallback? onProgress}) async {
    switch (plan.method) {
      case ImportMethod.download:
        return ImportedFile(plan.name, plan.mimeType, await drive.downloadBytes(file.id, onProgress: onProgress));
      case ImportMethod.export:
        return ImportedFile(plan.name, plan.mimeType, await drive.export(file.id, plan.mimeType, onProgress: onProgress));
      case ImportMethod.convert:
        final copy = await drive.copy(file.id, name: '~${p.withoutExtension(file.name)}', parentId: 'root', mimeType: plan.googleType);
        try { return ImportedFile(plan.name, plan.mimeType, await drive.export(copy, plan.mimeType, onProgress: onProgress)); }
        finally { try { await drive.delete(copy); } catch (_) {} }
      case ImportMethod.picture:
        return ImportedFile(plan.name, plan.mimeType, await _picture(file, onProgress));
    }
  }

  Future<Uint8List> _picture(DriveFile file, ProgressCallback? onProgress) async {
    try {
      return await toPng(await drive.downloadBytes(file.id, onProgress: onProgress));
    } on DriveException { rethrow; }
    catch (_) {
      // Not a format this device reads (e.g. HEIC on some, TIFF, SVG, camera RAW): Drive's own preview.
      final link = file.thumbnailLink;
      if (link == null) throw DriveException(trNow('docCannotRead'));
      try { return await toPng(await drive.downloadUrl(link.replaceFirst(RegExp(r'=s\d+(-[a-z]+)?$'), '=s$previewSize'))); }
      on DriveException { rethrow; }
      catch (_) { throw DriveException(trNow('docCannotRead')); }
    }
  }

  /// [bytes] (a picture in any format this device reads) as PNG.
  static Future<Uint8List> toPng(Uint8List bytes) => shrinkImage(bytes, 1 << 14);
}
