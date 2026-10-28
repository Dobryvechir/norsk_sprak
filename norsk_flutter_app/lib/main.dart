import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/l10n.dart';
import 'services/api.dart';
import 'services/settings.dart';
import 'screens/login_screen.dart';
import 'screens/menu_screen.dart';

void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const NorskApp()); }
class NorskApp extends StatefulWidget {
  const NorskApp({super.key});
  @override State<NorskApp> createState() => _NorskAppState();
}
class _NorskAppState extends State<NorskApp> {
  final api = Api();
  final settings = AppSettings.instance;
  bool loading = true;
  @override void initState() { super.initState(); _restore(); }
  Future<void> _restore() async { await settings.load(); await api.restore(); if (mounted) setState(() => loading = false); }
  @override Widget build(BuildContext context) => L10nScope(notifier: settings, child: ListenableBuilder(listenable: settings, builder: (context, _) => MaterialApp(
    title: 'Norsk Audio', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff315f72)),
    // Built-in widget texts (tooltips, dialogs) and text direction (Hebrew is right-to-left) follow the UI language.
    locale: localeFor(settings.uiLanguage),
    supportedLocales: [for (final code in languageNames.keys) localeFor(code)],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: loading ? const Scaffold(body: Center(child: CircularProgressIndicator())) :
      api.user == null ? LoginScreen(api: api, onLogin: () => setState(() {})) :
      MenuScreen(api: api, onLogout: () => setState(() {})),
  )));
}
