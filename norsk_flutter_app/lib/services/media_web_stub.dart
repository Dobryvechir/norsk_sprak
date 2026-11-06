import 'dart:typed_data';

Never _unsupported() => throw UnsupportedError('Only available in the web app');

String createObjectUrl(Uint8List bytes, String mimeType) => _unsupported();
void revokeObjectUrl(String url) => _unsupported();
Future<Uint8List?> videoFrameJpeg(String url, int maxSize) async => _unsupported();
