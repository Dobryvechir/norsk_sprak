import 'package:flutter/material.dart';
import 'services/api.dart';
import 'screens/login_screen.dart';
import 'screens/groups_screen.dart';

void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const NorskApp()); }
class NorskApp extends StatefulWidget {
  const NorskApp({super.key});
  @override State<NorskApp> createState() => _NorskAppState();
}
class _NorskAppState extends State<NorskApp> {
  final api = Api();
  bool loading = true;
  @override void initState() { super.initState(); _restore(); }
  Future<void> _restore() async { await api.restore(); if (mounted) setState(() => loading = false); }
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'Norsk Audio', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff315f72)),
    home: loading ? const Scaffold(body: Center(child: CircularProgressIndicator())) :
      api.user == null ? LoginScreen(api: api, onLogin: () => setState(() {})) :
      GroupsScreen(api: api, onLogout: () => setState(() {})),
  );
}
