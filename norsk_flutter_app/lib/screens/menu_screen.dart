import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:url_launcher/url_launcher.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/chat_api.dart';
import '../services/drive_auth.dart';
import '../services/notifications.dart';
import '../widgets/notification_view.dart';
import 'admin_menu_screen.dart';
import 'books_screen.dart';
import 'chat_screen.dart';
import 'documents_screen.dart';
import 'groups_screen.dart';
import 'media_screen.dart';
import 'saved_chapters_screen.dart';
import 'settings_screen.dart';
/// Main menu shown right after login.
class MenuScreen extends StatefulWidget {
  final Api api; final VoidCallback onLogout;
  const MenuScreen({super.key, required this.api, required this.onLogout});
  @override State<MenuScreen> createState() => _MenuScreenState();
}
class _MenuScreenState extends State<MenuScreen> {
  List<StudyGroup> groups = const [];
  /// Answers family members' "Find location" while the app runs (see ChatLocationResponder).
  late final locationResponder = ChatLocationResponder(ChatApi(widget.api));
  /// Back from the browser (e.g. after buying Pro): the groups may have changed.
  late final lifecycle = AppLifecycleListener(onResume: loadGroups);
  bool openingShop = false;
  /// A fatal notification for this user: the app then shows only it (see [exitApp]).
  AppNotification? fatal;
  /// Where a fatal notification sends the web app.
  static final exitUrl = Uri.parse('https://movna-hatka.com');
  @override void initState() {
    super.initState();
    lifecycle;
    locationResponder.start();
    final restored = widget.api.restoredGroups;
    widget.api.restoredGroups = null;
    if (restored != null) { groups = restored; } else { loadGroups(); }
    WidgetsBinding.instance.addPostFrameCallback((_) => showNotifications());
  }
  /// Right after login (or a restored session): shows this user's notifications, most severe first.
  /// A fatal one replaces the whole app, except for system admins, who must still be able to remove it.
  Future<void> showNotifications() async {
    final center = NotificationCenter(widget.api);
    final user = widget.api.user;
    final list = await center.pending();
    if (!mounted || user == null) return;
    final fatalOne = list.where((n) => n.isFatal).firstOrNull;
    if (fatalOne != null && !user.systemAdmin) { locationResponder.stop(); setState(() => fatal = fatalOne); return; }
    for (final n in list) {
      if (!mounted) return;
      if (n.showOnce) await center.dismiss(user.id, n.id);
      if (!mounted) return;
      if (await showNotificationDialog(context, n)) await center.dismiss(user.id, n.id);
    }
  }
  /// After a fatal notification: logs out and leaves - the web app goes to the company site,
  /// Android closes; where an app can't close itself (iOS) the login page is shown.
  Future<void> exitApp() async {
    DriveAuth.instance.signOut();
    await widget.api.logout();
    if (kIsWeb) {
      try { if (await launchUrl(exitUrl, webOnlyWindowName: '_self')) return; } catch (_) {}
    } else {
      await SystemNavigator.pop();
    }
    widget.onLogout();
  }
  /// The groups decide whether the Admin entry is shown (admin of at least one group).
  Future<void> loadGroups() async {
    // Reaching the server also ends an offline start (see Api.offline).
    try { final g = await widget.api.groups(); widget.api.offline = false; if (mounted) setState(() => groups = g); }
    catch (_) {} // keep the previous list; system admins see Admin regardless
  }
  Future<void> open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    loadGroups(); // roles may have changed meanwhile
  }
  @override void dispose() { lifecycle.dispose(); locationResponder.stop(); super.dispose(); }
  /// Opens the Pro plan page in the web browser, with a link made for this user.
  Future<void> changeToPro() async {
    if (openingShop) return;
    setState(() => openingShop = true);
    String? error;
    try {
      final link = await widget.api.upgradeLink();
      var ok = false;
      try { ok = await launchUrl(link, mode: LaunchMode.externalApplication); } catch (_) {}
      if (!ok && mounted) error = context.tr('linkOpenFailed', {'url': '$link'});
    } catch (e) { error = readableError(e); }
    if (!mounted) return;
    setState(() => openingShop = false);
    if (error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }
  Future<void> logout() async { locationResponder.stop(); DriveAuth.instance.signOut(); await widget.api.logout(); widget.onLogout(); }
  Widget entry(IconData icon, String label, VoidCallback onTap) => Card(child: ListTile(
    leading: Icon(icon), title: Text(label), trailing: const Icon(Icons.chevron_right), onTap: onTap));
  @override Widget build(BuildContext context) => fatal != null ? FatalNotificationView(notification: fatal!, onExit: exitApp) : Scaffold(
    appBar: AppBar(title: const Text('Norsk Audio')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: ListView(padding: const EdgeInsets.all(16), children: [
      if (widget.api.user != null) Padding(padding: const EdgeInsets.only(bottom: 12),
        child: Text(context.tr('signedInAs', {'email': widget.api.user!.email}), textAlign: TextAlign.center)),
      if (widget.api.offline) Card(color: Theme.of(context).colorScheme.secondaryContainer, child: ListTile(
        leading: const Icon(Icons.cloud_off), title: Text(context.tr('offlineMode')),
        trailing: IconButton(tooltip: context.tr('refresh'), onPressed: loadGroups, icon: const Icon(Icons.refresh)))),
      if (widget.api.canChangeToPro(groups)) entry(Icons.workspace_premium, context.tr('menuChangeToPro'), changeToPro),
      entry(Icons.headphones, context.tr('menuRecords'), () => open(GroupsScreen(api: widget.api))),
      entry(Icons.menu_book, context.tr('menuBooks'), () => open(BooksScreen(api: widget.api))),
      // Documents are kept on this device; only their synchronization needs Google Drive.
      entry(Icons.folder_copy, context.tr('menuDocuments'), () => open(const DocumentsScreen())),
      // Media works with the user's own Google Drive; its first Drive call opens Google's sign-in when needed.
      entry(Icons.perm_media, context.tr('menuMedia'), () => open(const MediaScreen())),
      entry(Icons.download_done, context.tr('menuSaved'), () => open(SavedChaptersScreen(api: widget.api))),
      entry(Icons.chat_bubble_outline, context.tr('menuChat'), () => open(ChatScreen(api: widget.api))),
      entry(Icons.settings, context.tr('menuSettings'), () => open(SettingsScreen(api: widget.api))),
      if (widget.api.hasAdminRights(groups)) entry(Icons.admin_panel_settings, context.tr('menuAdmin'), () => open(AdminMenuScreen(api: widget.api))),
      entry(Icons.logout, context.tr('menuLogout'), logout),
    ]))),
  );
}
