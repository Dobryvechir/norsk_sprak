@TestOn('browser')
library;

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/services/web_store.dart' as store;

// Run with: flutter test --platform chrome test/web_store_test.dart
void main() {
  test('chapters and their audio are saved in IndexedDB, played from a blob: URL, and removed', () async {
    await store.removeChapter('t-1');
    await store.putChapter('t-1', '{"id":"t-1"}');
    await store.putAudio('t-1', 'nb', Uint8List.fromList(List.generate(2 * 1024 * 1024, (i) => i % 256)), 'audio/mpeg');
    await store.putAudio('t-10', 'nb', Uint8List.fromList([1]), 'audio/mpeg'); // a chapter whose id starts the same

    expect(await store.getChapter('t-1'), '{"id":"t-1"}');
    expect(await store.chapterIds(), contains('t-1'));
    expect(await store.hasAudio('t-1', 'nb'), isTrue);
    final url = await store.audioObjectUrl('t-1', 'nb');
    expect(url, startsWith('blob:'));
    store.revokeObjectUrl(url!);
    expect(await store.audioObjectUrl('t-1', 'en'), isNull);

    await store.removeChapter('t-1');
    expect(await store.getChapter('t-1'), isNull);
    expect(await store.hasAudio('t-1', 'nb'), isFalse);
    expect(await store.hasAudio('t-10', 'nb'), isTrue);
    await store.removeAudio('t-10');
    await store.requestPersistence();
  });
}
