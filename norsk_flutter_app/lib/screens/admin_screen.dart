import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
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
      title: Text(context.tr('addMember')), content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: user, decoration: InputDecoration(labelText: context.tr('existingUserId'))),
        DropdownButton<String>(value: role, isExpanded: true, items: ['viewer','uploader','admin'].map((x) => DropdownMenuItem(value: x, child: Text(context.trRole(x)))).toList(), onChanged: (v) => update(() => role = v!)),
      ]), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, (user.text.trim(),role)), child: Text(context.tr('add')))])));
    if (result == null || result.$1.isEmpty) return;
    try { await widget.api.addMember(widget.group.id, result.$1, result.$2); refresh(); }
    catch (e) { showError(e); }
  }
  void showError(Object e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
  Future<void> edit(Membership m) async {
    String role = m.role; bool enabled = m.enabled;
    final records = TextEditingController(text: m.quota['max_recordings_per_month']?.toString() ?? '');
    final minutes = TextEditingController(text: m.quota['max_audio_minutes_per_month']?.toString() ?? '');
    final duration = TextEditingController(text: m.quota['max_recording_duration_minutes']?.toString() ?? '');
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx,update) => AlertDialog(
      title: Text(context.tr('membershipTitle', {'id': m.userId})), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButton<String>(value: role, isExpanded: true, items: ['viewer','uploader','admin'].map((x) => DropdownMenuItem(value: x, child: Text(context.trRole(x)))).toList(), onChanged:(v)=>update(()=>role=v!)),
        SwitchListTile(title: Text(context.tr('enabled')), value: enabled, onChanged:(v)=>update(()=>enabled=v)),
        TextField(controller: records, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.tr('maxUploadsPerMonth'))),
        TextField(controller: minutes, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.tr('maxMinutesPerMonth'))),
        TextField(controller: duration, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.tr('maxRecordingDuration'))),
      ])), actions: [TextButton(onPressed: () => Navigator.pop(ctx,false), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx,true), child: Text(context.tr('save')))])));
    if (ok == true) {
      try {
        int? parse(TextEditingController c) { if (c.text.trim().isEmpty) return null; final n=int.parse(c.text.trim()); if(n<0) throw FormatException(trNow('quotaNonNegative')); return n; }
        await widget.api.updateMember(widget.group.id,m,role,enabled,{
          'max_recordings_per_month': parse(records), 'max_audio_minutes_per_month': parse(minutes),
          'max_recording_duration_minutes': parse(duration),
        }); refresh();
      } catch (e) { showError(e); }
    }
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(context.tr('manageGroup', {'name': widget.group.name})), actions: [IconButton(tooltip: context.tr('refresh'), onPressed: refresh, icon: const Icon(Icons.refresh))]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 8, children: [
        FilledButton.icon(onPressed: addMember, icon: const Icon(Icons.person_add), label: Text(context.tr('addMember'))),
      ])),
      Expanded(child: FutureBuilder<List<Membership>>(future: future, builder: (ctx,snap) {
        if (!snap.hasData) return Center(child: snap.hasError ? Text(context.tr('adminPermissionRequired', {'error': readableError(snap.error!)})) : const CircularProgressIndicator());
        if (snap.data!.isEmpty) return Center(child: Text(context.tr('noMembers')));
        return ListView.builder(itemCount: snap.data!.length, itemBuilder: (ctx,i) {
          final m=snap.data![i]; return ListTile(title: Text(m.userId),
            subtitle: Text(context.tr('memberSummary', {'role': context.trRole(m.role), 'state': context.tr(m.enabled ? 'stateEnabled' : 'stateDisabled'), 'quota': m.quota})),
            trailing: const Icon(Icons.edit), onTap: () => edit(m));
        });
      })),
    ]));
}
