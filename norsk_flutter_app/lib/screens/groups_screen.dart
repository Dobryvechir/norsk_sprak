import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import 'library_screen.dart';
class GroupsScreen extends StatefulWidget {
  final Api api;
  const GroupsScreen({super.key, required this.api});
  @override State<GroupsScreen> createState() => _GroupsScreenState();
}
class _GroupsScreenState extends State<GroupsScreen> {
  late Future<List<StudyGroup>> groups;
  @override void initState() { super.initState(); refresh(); }
  void refresh() { setState(() { groups = widget.api.groups(); }); }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('menuRecords')), actions: [
      IconButton(tooltip: context.tr('refresh'), onPressed: refresh, icon: const Icon(Icons.refresh))]),
    body: FutureBuilder<List<StudyGroup>>(future: groups, builder: (ctx, snap) {
      if (!snap.hasData) return Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator());
      if (snap.data!.isEmpty) {
          return Center(child: Text(context.tr('noGroups')));
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
