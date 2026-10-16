import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:norsk_audio_groups/main.dart';

void main() {
  testWidgets('App starts with a loading indicator', (WidgetTester tester) async {
    await tester.pumpWidget(const NorskApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
