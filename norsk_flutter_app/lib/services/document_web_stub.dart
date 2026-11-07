import 'dart:typed_data';

Never _unsupported() => throw UnsupportedError('Only available in the web app');

Future<List<(String, int)>> listDocuments(String folder) async => _unsupported();
Future<bool> hasDocument(String folder, String name) async => _unsupported();
Future<Uint8List?> readDocument(String folder, String name) async => _unsupported();
Future<void> writeDocument(String folder, String name, Uint8List bytes, String type) async => _unsupported();
Future<void> deleteDocument(String folder, String name) async => _unsupported();
