import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/models/entities.dart';
void main() {
  test('parses recording and sentence milliseconds', () {
    final r = Recording.fromJson({
      'id': 'r1', 'group_id': 'g1', 'name': 'Hei', 'status': 'ready',
      'duration_seconds': 60.0,
      'sentences': [{'index': 0, 'text': 'Hei!', 'start_ms': 100, 'end_ms': 1200}],
    });
    expect(r.sentences.single.startMs, 100);
    expect(r.sentences.single.endMs, 1200);
    expect(r.groupId, 'g1');
  });
}
