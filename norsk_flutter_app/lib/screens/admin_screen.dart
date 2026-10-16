import 'package:flutter/material.dart';
import '../models/entities.dart';
import '../services/api.dart';
class AdminScreen extends StatefulWidget {
  final Api api; final StudyGroup group;
  const AdminScreen({super.key, required this.api, required this.group});
  @override State<AdminScreen> createState() => _AdminScreenState();
}
class _AdminScreenState extends State<AdminScreen> {
  late Future<List<Membership>> future;
  @override void initState() { super.initState(); refresh(); }
  void refresh() => setState(() { future = widget.api.members(widget.group.id); });
  Future<void> addMember() async {
    final user = TextEditingController(); String role = 'viewer';
    final result = await showDialog<(String,String)>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, update) => AlertDialog(
      title: const Text('Add member'), content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: user, decoration: const InputDecoration(labelText: 'Existing user ID')),
        DropdownButton<String>(value: role, isExpanded: true, items: ['viewer','uploader','admin'].map((x) => DropdownMenuItem(value: x, child: Text(x))).toList(), onChanged: (v) => update(() => role = v!)),
      ]), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, (user.text.trim(),role)), child: const Text('Add'))])));
    if (result == null || result.$1.isEmpty) return;
    try { await widget.api.addMember(widget.group.id, result.$1, result.$2); refresh(); }
    catch (e) { showError(e); }
  }
  void showError(Object e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
  Future<void> createUser() async {
    final email = TextEditingController(); final password = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Create user (system admin)'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: email, decoration: const InputDecoration(labelText: 'Email')),
        TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password (10+ chars)')),
      ]), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create'))]));
    if (ok == true) { try { final created = await widget.api.createUser(email.text, password.text); if (mounted) await showDialog<void>(context: context, builder: (ctx) => AlertDialog(title: const Text('User created'), content: SelectableText('User ID: ${created.id}\nEmail: ${created.email}\nUse this ID when adding the user to a group.'), actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))])); }
      catch (e) { showError(e); } }
  }
  Future<void> edit(Membership m) async {
    String role = m.role; bool enabled = m.enabled;
    final records = TextEditingController(text: m.quota['max_recordings_per_month']?.toString() ?? '');
    final minutes = TextEditingController(text: m.quota['max_audio_minutes_per_month']?.toString() ?? '');
    final duration = TextEditingController(text: m.quota['max_recording_duration_minutes']?.toString() ?? '');
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx,update) => AlertDialog(
      title: Text('Membership: ${m.userId}'), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButton<String>(value: role, isExpanded: true, items: ['viewer','uploader','admin'].map((x) => DropdownMenuItem(value:x,child:Text(x))).toList(), onChanged:(v)=>update(()=>role=v!)),
        SwitchListTile(title: const Text('Enabled'), value: enabled, onChanged:(v)=>update(()=>enabled=v)),
        TextField(controller: records, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Max uploads per month (blank = unlimited)')),
        TextField(controller: minutes, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Max audio minutes per month')),
        TextField(controller: duration, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Max duration per recording (minutes)')),
      ])), actions: [TextButton(onPressed: () => Navigator.pop(ctx,false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx,true), child: const Text('Save'))])));
    if (ok == true) {
      try {
        int? parse(TextEditingController c) { if (c.text.trim().isEmpty) return null; final n=int.parse(c.text.trim()); if(n<0) throw const FormatException('Quota must be non-negative'); return n; }
        await widget.api.updateMember(widget.group.id,m,role,enabled,{
          'max_recordings_per_month': parse(records), 'max_audio_minutes_per_month': parse(minutes),
          'max_recording_duration_minutes': parse(duration),
        }); refresh();
      } catch (e) { showError(e); }
    }
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text('Manage ${widget.group.name}'), actions: [IconButton(onPressed: refresh, icon: const Icon(Icons.refresh))]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 8, children: [
        FilledButton.icon(onPressed: addMember, icon: const Icon(Icons.person_add), label: const Text('Add member')),
        if (widget.api.user?.systemAdmin == true) OutlinedButton.icon(onPressed: createUser, icon: const Icon(Icons.person_add_alt), label: const Text('Create user')),
      ])),
      Expanded(child: FutureBuilder<List<Membership>>(future: future, builder: (ctx,snap) {
        if (!snap.hasData) return Center(child: snap.hasError ? Text('Admin permission required: ${readableError(snap.error!)}') : const CircularProgressIndicator());
        if (snap.data!.isEmpty) return const Center(child: Text('No members.'));
        return ListView.builder(itemCount: snap.data!.length, itemBuilder: (ctx,i) {
          final m=snap.data![i]; return ListTile(title: Text(m.userId),
            subtitle: Text('${m.role} · ${m.enabled ? 'enabled' : 'disabled'} · quota ${m.quota}'),
            trailing: const Icon(Icons.edit), onTap: () => edit(m));
        });
      })),
    ]));
}
