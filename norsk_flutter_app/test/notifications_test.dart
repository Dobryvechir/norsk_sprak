import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/l10n/l10n.dart';
import 'package:norsk_audio_groups/models/entities.dart';
import 'package:norsk_audio_groups/services/notifications.dart';
void main() {
  AppNotification n(String id, int severity) => AppNotification(id, 'text $id', severity);

  test('severity decides the level', () {
    expect([0, 10, 11, 20, 21, 30, 31, 99].map((s) => n('x', s).level), [
      NotificationLevel.info, NotificationLevel.info, NotificationLevel.warning, NotificationLevel.warning,
      NotificationLevel.critical, NotificationLevel.critical, NotificationLevel.fatal, NotificationLevel.fatal]);
  });

  test('last digit decides how often', () {
    expect(n('a', 10).showAlways, isTrue);
    expect(n('a', 21).showOnce, isTrue);
    for (final s in [2, 13, 25, 29]) { expect(n('a', s).dismissible, isTrue, reason: '$s'); }
    // A fatal notification is always shown, whatever its last digit.
    for (final s in [31, 40, 32]) {
      final f = n('f', s);
      expect([f.showAlways, f.showOnce, f.dismissible], [false, false, false], reason: '$s');
    }
  });

  test('dismissed ids are skipped unless always shown or fatal; most severe first', () {
    final all = [n('once', 1), n('always', 20), n('remind', 12), n('fatal', 31), n('kept', 22)];
    final shown = NotificationCenter.toShow(all, {'once', 'always', 'remind', 'fatal'});
    expect(shown.map((x) => x.id), ['fatal', 'kept', 'always']);
  });

  test('parses the server JSON', () {
    final x = AppNotification.fromJson({'id': 'n1', 'text': 'Hi', 'severity': 12, 'groupId': 'g1', 'privilegeFrom': 0,
      'versionTo': '1.0', 'datetimeFrom': '2026-11-14T10:00:00+00:00', 'datetimeTo': null});
    expect(x.groupId, 'g1');
    expect(x.privilegeFrom, 0);
    expect(x.privilegeTo, isNull);
    expect(x.versionTo, '1.0');
    expect(x.datetimeFrom!.toUtc(), DateTime.utc(2026, 11, 14, 10));
    expect(x.datetimeTo, isNull);
  });

  test('every language has the notification texts', () {
    for (final lang in translations.keys) {
      for (final key in ['notifications', 'doNotRemindAgain', 'severityHint', 'appVersion']) {
        expect(translations[lang]![key], isNotNull, reason: '$lang $key');
      }
    }
  });
}
