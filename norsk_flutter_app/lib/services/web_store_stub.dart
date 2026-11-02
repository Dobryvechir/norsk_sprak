import 'dart:typed_data';

Never _unsupported() => throw UnsupportedError('The web store exists only in the web app');

Future<void> putChapter(String id, String json) async => _unsupported();
Future<String?> getChapter(String id) async => _unsupported();
Future<List<String>> chapterIds() async => _unsupported();
Future<void> putAudio(String id, String language, Uint8List bytes, String type) async => _unsupported();
Future<bool> hasAudio(String id, String language) async => _unsupported();
Future<String?> audioObjectUrl(String id, String language) async => _unsupported();
void revokeObjectUrl(String url) => _unsupported();
Future<void> removeAudio(String id) async => _unsupported();
Future<void> removeChapter(String id) async => _unsupported();
Future<void> requestPersistence() async => _unsupported();
