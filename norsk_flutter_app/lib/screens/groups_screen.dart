import 'package:flutter/material.dart';
import '../models/entities.dart';
import '../services/api.dart';
import 'library_screen.dart';
class GroupsScreen extends StatefulWidget {
  final Api api; final VoidCallback onLogout;
  const GroupsScreen({super.key, required this.api, required this.onLogout});
  @override State<GroupsScreen> createState() => _GroupsScreenState();
}
class _GroupsScreenState extends State<GroupsScreen> {
  late Future<List<StudyGroup>> groups;
  @override void initState() { super.initState(); refresh(); }
  void refresh() { setState(() { groups = widget.api.groups(); }); }
  Future<void> createGroup() async {
    final c = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(title: const Text('Create group'),
      content: TextField(controller: c, decoration: const InputDecoration(labelText: 'Group name')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Create'))]));
    if (name == null || name.isEmpty) return;
    try { await widget.api.createGroup(name); refresh(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('My groups'), actions: [
      if (widget.api.user?.systemAdmin == true) IconButton(tooltip: 'Create group', onPressed: createGroup, icon: const Icon(Icons.add)),
      IconButton(tooltip: 'Refresh', onPressed: refresh, icon: const Icon(Icons.refresh)),
      IconButton(tooltip: 'Sign out', onPressed: () async { await widget.api.logout(); widget.onLogout(); }, icon: const Icon(Icons.logout))]),
    body: FutureBuilder<List<StudyGroup>>(future: groups, builder: (ctx, snap) {
      if (!snap.hasData) return Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator());
      if (snap.data!.isEmpty) {
          return const Center(child: Text('You are not a member of any group yet.'));
      }
      return ListView.builder(itemCount: snap.data!.length, itemBuilder: (ctx, i) { final group = snap.data![i];
        return ListTile(leading: const Icon(Icons.groups), title: Text(group.name), subtitle: Text(group.id),
          trailing: const Icon(Icons.chevron_right), 
          onTap: () => Navigator.push(ctx, MaterialPageRoute(builder:
              (_) => LibraryScreen(api: widget.api, group: group))));
       });
    }),
  );
}
