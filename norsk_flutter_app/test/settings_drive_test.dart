import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/l10n/l10n.dart';
import 'package:norsk_audio_groups/screens/settings_screen.dart';
import 'package:norsk_audio_groups/services/api.dart';
import 'package:norsk_audio_groups/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final settings = AppSettings.instance;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() { settings.driveConnected = false; settings.driveEmail = null; });

  Future<void> pump(WidgetTester tester) async {
    // Tall enough for the lazy list to build the Drive section.
    tester.view..physicalSize = const Size(800, 2400)..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(L10nScope(notifier: settings, child: MaterialApp(home: SettingsScreen(api: Api()))));
  }

  testWidgets('unconnected: a connect button, disabled while no client ID is set', (tester) async {
    await pump(tester);
    final button = tester.widget<ButtonStyleButton>(find.ancestor(of: find.text('Connect Google Drive'), matching: find.bySubtype<ButtonStyleButton>()));
    expect(button.onPressed, isNull);
    expect(find.text('Google sign-in is not set up in this version of the app.'), findsOneWidget);
  });

  testWidgets('connected: shows the account and follows the connection', (tester) async {
    settings..driveConnected = true..driveEmail = 'a@b.no';
    await pump(tester);
    expect(find.text('Connected to Google Drive as a@b.no'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Connect Google Drive'), findsNothing);

    await settings.setDriveConnection(true);
    await tester.pump();
    expect(find.text('Connected to Google Drive'), findsOneWidget, reason: 'the web flow gives no address');

    await settings.setDriveConnection(false);
    await tester.pump();
    expect(find.text('Connect Google Drive'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
  });
}
