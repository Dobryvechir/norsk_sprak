import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import 'admin_screen.dart';
/// Everything admin-related: creating groups and users (system admin) and
/// managing the members of each group the user administers.
class AdminMenuScreen extends StatefulWidget {
  final Api api;
  const AdminMenuScreen({super.key, required this.api});
  @override State<AdminMenuScreen> createState() => _AdminMenuScreenState();
}
class _AdminMenuScreenState extends State<AdminMenuScreen> {
  late Future<List<StudyGroup>> groups;
  bool get systemAdmin => widget.api.user?.systemAdmin == true;
  @override void initState() { super.initState(); refresh(); }
  void refresh() => setState(() { groups = widget.api.groups(); });
  void showError(Object e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
  Future<void> createGroup() async {
    final c = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(title: Text(context.tr('createGroup')),
      content: TextField(controller: c, decoration: InputDecoration(labelText: context.tr('groupName'))),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(context.tr('create')))]));
    if (name == null || name.isEmpty) return;
    try { await widget.api.createGroup(name); refresh(); }
    catch (e) { showError(e); }
  }
  Future<void> createUser() async {
    final email = TextEditingController(); final password = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: Text(context.tr('createUserTitle')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: email, decoration: InputDecoration(labelText: context.tr('email'))),
        TextField(controller: password, obscureText: true, decoration: InputDecoration(labelText: context.tr('passwordMinLength'))),
      ]), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.tr('create')))]));
    if (ok == true) { try { final created = await widget.api.createUser(email.text, password.text); if (mounted) await showDialog<void>(context: context, builder: (ctx) => AlertDialog(title: Text(context.tr('userCreated')), content: SelectableText(context.tr('userCreatedInfo', {'id': created.id, 'email': created.email})), actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(context.tr('ok')))])); }
      catch (e) { showError(e); } }
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('menuAdmin')), actions: [IconButton(tooltip: context.tr('refresh'), onPressed: refresh, icon: const Icon(Icons.refresh))]),
    body: FutureBuilder<List<StudyGroup>>(future: groups, builder: (ctx, snap) {
      final adminGroups = (snap.data ?? const <StudyGroup>[]).where((g) => systemAdmin || g.isAdmin).toList();
      return ListView(padding: const EdgeInsets.all(12), children: [
        if (systemAdmin) ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(onPressed: createGroup, icon: const Icon(Icons.group_add), label: Text(context.tr('createGroup'))),
            OutlinedButton.icon(onPressed: createUser, icon: const Icon(Icons.person_add_alt), label: Text(context.tr('createUser'))),
          ]),
          const SizedBox(height: 16),
        ],
        Text(context.tr('groupMembers'), style: Theme.of(context).textTheme.titleMedium),
        if (!snap.hasData) Padding(padding: const EdgeInsets.all(24), child: Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator()))
        else if (adminGroups.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(context.tr('noAdminGroups'), textAlign: TextAlign.center))
        else for (final group in adminGroups) ListTile(leading: const Icon(Icons.manage_accounts), title: Text(group.name), subtitle: Text(group.id),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AdminScreen(api: widget.api, group: group)))),
      ]);
    }),
  );
}
