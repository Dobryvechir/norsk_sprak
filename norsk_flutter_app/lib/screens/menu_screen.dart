import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import 'admin_menu_screen.dart';
import 'books_screen.dart';
import 'coming_soon_screen.dart';
import 'groups_screen.dart';
import 'settings_screen.dart';
/// Main menu shown right after login.
class MenuScreen extends StatefulWidget {
  final Api api; final VoidCallback onLogout;
  const MenuScreen({super.key, required this.api, required this.onLogout});
  @override State<MenuScreen> createState() => _MenuScreenState();
}
class _MenuScreenState extends State<MenuScreen> {
  List<StudyGroup> groups = const [];
  @override void initState() {
    super.initState();
    final restored = widget.api.restoredGroups;
    widget.api.restoredGroups = null;
    if (restored != null) { groups = restored; } else { loadGroups(); }
  }
  /// The groups decide whether the Admin entry is shown (admin of at least one group).
  Future<void> loadGroups() async {
    try { final g = await widget.api.groups(); if (mounted) setState(() => groups = g); }
    catch (_) {} // keep the previous list; system admins see Admin regardless
  }
  Future<void> open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    loadGroups(); // roles may have changed meanwhile
  }
  Future<void> logout() async { await widget.api.logout(); widget.onLogout(); }
  Widget entry(IconData icon, String label, VoidCallback onTap) => Card(child: ListTile(
    leading: Icon(icon), title: Text(label), trailing: const Icon(Icons.chevron_right), onTap: onTap));
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Norsk Audio')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: ListView(padding: const EdgeInsets.all(16), children: [
      if (widget.api.user != null) Padding(padding: const EdgeInsets.only(bottom: 12),
        child: Text(context.tr('signedInAs', {'email': widget.api.user!.email}), textAlign: TextAlign.center)),
      entry(Icons.headphones, context.tr('menuRecords'), () => open(GroupsScreen(api: widget.api))),
      entry(Icons.menu_book, context.tr('menuBooks'), () => open(BooksScreen(api: widget.api))),
      entry(Icons.chat_bubble_outline, context.tr('menuChat'), () => open(const ComingSoonScreen(titleKey: 'menuChat'))),
      entry(Icons.settings, context.tr('menuSettings'), () => open(const SettingsScreen())),
      if (widget.api.hasAdminRights(groups)) entry(Icons.admin_panel_settings, context.tr('menuAdmin'), () => open(AdminMenuScreen(api: widget.api))),
      entry(Icons.logout, context.tr('menuLogout'), logout),
    ]))),
  );
}
