import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/version.dart';
void main() {
  test('appVersion matches pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(appVersion, line.substring('version:'.length).trim());
  });
}
