import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/models/entities.dart';
void main() {
  final r = Recording.fromJson({
    'id': 'r1', 'group_id': 'g1', 'name': 'Hei',
    'audio': {
      'nb': {'status': 'ready', 'duration_seconds': 60.0, 'created_at': '2026-10-17T10:00:00+00:00',
        'start_ms': [100, 1300], 'end_ms': [1200, 2500]},
      'en': {'status': 'pending', 'duration_seconds': 55.0, 'start_ms': [], 'end_ms': []},
    },
    'sentences': {'nb': ['Hei!', 'God dag.'], 'en': ['Hi!']},
  });

  test('parses audio per language and sentences per language', () {
    expect(r.groupId, 'g1');
    expect(r.audio.keys, containsAll(['nb', 'en']));
    expect(r.audio['en']!.isTranscribing, isTrue);
    expect(r.sentenceCount, 2);
    expect(r.text('en', 0), 'Hi!');
    expect(r.text('en', 1), '');
  });

  test('timed sentences combine one language\'s timings and texts', () {
    final timed = r.timedSentences('nb');
    expect(timed.length, 2);
    expect(timed[1].startMs, 1300);
    expect(timed[1].endMs, 2500);
    expect(timed[1].text, 'God dag.');
    expect(r.timedSentences('en'), isEmpty);
    expect(r.timedSentences('de'), isEmpty);
  });

  test('signup candidate: verification, plan, payment and suggested group', () {
    final c = SignupCandidate.fromJson({'id': 'c1', 'email': 'a@b.no', 'status': 'pending',
      'created_at': '2026-11-14T10:00:00+00:00', 'email_verified': true, 'plan': 'pro',
      'payment': {'status': 'failed', 'method': 'vipps'}, 'default_group_id': 'g-basic'});
    expect(c.emailVerified, isTrue);
    expect(c.plan, 'pro');
    expect(c.paymentStatus, 'failed');
    expect(c.paymentMethod, 'vipps');
    expect(c.defaultGroupId, 'g-basic');
    final old = SignupCandidate.fromJson({'id': 'c2', 'email': 'x@y.no', 'status': 'pending'});
    expect(old.emailVerified, isFalse);
    expect(old.plan, isNull);
    expect(old.paymentStatus, isNull);
  });
}
