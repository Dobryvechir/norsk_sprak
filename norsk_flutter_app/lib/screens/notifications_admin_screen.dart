import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../version.dart';
import '../widgets/notification_view.dart';

/// System admin: view, create and remove the notifications shown in the app
/// (see the server's routes/notifications.py for who receives which).
class NotificationsAdminScreen extends StatefulWidget {
  final Api api;
  const NotificationsAdminScreen({super.key, required this.api});
  @override State<NotificationsAdminScreen> createState() => _NotificationsAdminScreenState();
}

String _two(int n) => n.toString().padLeft(2, '0');
String formatDateTime(DateTime? d) => d == null ? '' : '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

class _NotificationsAdminScreenState extends State<NotificationsAdminScreen> {
  late Future<List<AppNotification>> future;
  List<StudyGroup> groups = const [];
  @override void initState() { super.initState(); refresh(); loadGroups(); }
  void refresh() => setState(() { future = widget.api.allNotifications(); });
  Future<void> loadGroups() async {
    try { final list = await widget.api.groups(); if (mounted) setState(() => groups = list); } catch (e) { showError(e); }
  }
  void showError(Object e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
  String groupName(String id) => groups.firstWhere((g) => g.id == id, orElse: () => StudyGroup(id, id)).name;

  Future<void> create() async {
    final fields = await Navigator.push<Map<String, dynamic>>(context, MaterialPageRoute(builder: (_) => _NotificationForm(groups: groups)));
    if (fields == null) return;
    try { await widget.api.createNotification(fields); refresh(); } catch (e) { showError(e); }
  }
  Future<void> remove(AppNotification n) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      content: Text(context.tr('deleteNotificationConfirm')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.tr('delete')))]));
    if (ok != true) return;
    try { await widget.api.deleteNotification(n.id); refresh(); } catch (e) { showError(e); }
  }

  String repeatText(AppNotification n) => context.tr(n.isFatal ? 'notificationFatalShort'
    : n.showAlways ? 'repeatAlways' : n.showOnce ? 'repeatOnce' : 'repeatUntilDismissed');
  String recipients(AppNotification n) {
    if (n.userId != null) return context.tr('forUser', {'user': n.userId});
    if (n.groupId != null) return context.tr('forGroup', {'group': groupName(n.groupId!)});
    if (n.privilegeFrom != null || n.privilegeTo != null) {
      return context.tr('forPrivilege', {'from': n.privilegeFrom ?? '…', 'to': n.privilegeTo ?? '…'});
    }
    return context.tr('recipientsEveryone');
  }

  Widget card(AppNotification n) {
    final theme = Theme.of(context);
    final (icon, color, title) = notificationStyle(context, n.level);
    Widget chip(String text, [IconData? chipIcon]) => Chip(avatar: chipIcon == null ? null : Icon(chipIcon, size: 16),
      label: Text(text), visualDensity: VisualDensity.compact);
    return Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: color)),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text('$title · ${context.tr('severityValue', {'severity': n.severity})} · ${repeatText(n)}',
            style: theme.textTheme.titleSmall?.copyWith(color: color))),
          IconButton(tooltip: context.tr('delete'), onPressed: () => remove(n), icon: const Icon(Icons.delete_outline)),
        ]),
        SelectableText(n.text),
        Padding(padding: const EdgeInsets.only(top: 8), child: Wrap(spacing: 8, runSpacing: 4, children: [
          chip(recipients(n), Icons.people_outline),
          if (n.versionFrom != null || n.versionTo != null)
            chip(context.tr('versionRange', {'from': n.versionFrom ?? '…', 'to': n.versionTo ?? '…'}), Icons.tag),
          if (n.datetimeFrom != null || n.datetimeTo != null)
            chip('${formatDateTime(n.datetimeFrom).isEmpty ? '…' : formatDateTime(n.datetimeFrom)} – '
              '${formatDateTime(n.datetimeTo).isEmpty ? '…' : formatDateTime(n.datetimeTo)}', Icons.schedule),
        ])),
        if (n.createdAt != null) Padding(padding: const EdgeInsets.only(top: 6),
          child: Text(context.tr('createdAt', {'date': formatDateTime(n.createdAt)}), style: theme.textTheme.bodySmall)),
      ])));
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('notifications')), actions: [IconButton(tooltip: context.tr('refresh'), onPressed: refresh, icon: const Icon(Icons.refresh))]),
    floatingActionButton: FloatingActionButton.extended(onPressed: create, icon: const Icon(Icons.add), label: Text(context.tr('createNotification'))),
    body: FutureBuilder<List<AppNotification>>(future: future, builder: (ctx, snap) {
      final version = Card(child: ListTile(leading: const Icon(Icons.info_outline), title: Text(context.tr('currentAppVersion', {'version': appVersion}))));
      if (!snap.hasData) {
        return ListView(padding: const EdgeInsets.all(12), children: [version, Padding(padding: const EdgeInsets.all(24),
          child: Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator()))]);
      }
      final list = snap.data!;
      return RefreshIndicator(onRefresh: () async { refresh(); await future; },
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 88), children: [
          version,
          if (list.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(context.tr('noNotifications'))))
          else for (final n in list) card(n),
        ]));
    }),
  );
}

enum _Recipients { everyone, user, group, privilege }

/// The "Create notification" page; pops with the fields for POST /api/admin/notifications.
class _NotificationForm extends StatefulWidget {
  final List<StudyGroup> groups;
  const _NotificationForm({required this.groups});
  @override State<_NotificationForm> createState() => _NotificationFormState();
}
class _NotificationFormState extends State<_NotificationForm> {
  final formKey = GlobalKey<FormState>();
  final text = TextEditingController(), severity = TextEditingController(text: '2'), user = TextEditingController();
  final versionFrom = TextEditingController(), versionTo = TextEditingController();
  final privilegeFrom = TextEditingController(), privilegeTo = TextEditingController();
  _Recipients recipients = _Recipients.everyone;
  String? groupId;
  DateTime? from, to;

  @override void dispose() {
    for (final c in [text, severity, user, versionFrom, versionTo, privilegeFrom, privilegeTo]) { c.dispose(); }
    super.dispose();
  }

  static final _version = RegExp(r'^\d+(\.\d+)*([+\-].*)?$');
  String? numberValidator(String? v, {bool required = false}) {
    final value = (v ?? '').trim();
    if (value.isEmpty) return required ? context.tr('fieldRequired') : null;
    return int.tryParse(value) == null ? context.tr('invalidNumber') : null;
  }
  String? versionValidator(String? v) => (v ?? '').trim().isEmpty || _version.hasMatch(v!.trim()) ? null : context.tr('invalidVersion');

  Future<void> pickDateTime(bool start) async {
    final initial = (start ? from : to) ?? DateTime.now();
    final date = await showDatePicker(context: context, initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 365)), lastDate: DateTime.now().add(const Duration(days: 3650)));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null) return;
    final value = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() => start ? from = value : to = value);
  }

  NotificationLevel? get level { final s = int.tryParse(severity.text.trim()); return s == null || s < 0 ? null
    : AppNotification('', '', s).level; }
  String severityDescription() {
    final s = int.tryParse(severity.text.trim());
    if (s == null || s < 0) return context.tr('severityHint');
    final n = AppNotification('', '', s);
    final (_, _, title) = notificationStyle(context, n.level);
    final repeat = n.isFatal ? 'notificationFatalShort' : n.showAlways ? 'repeatAlways' : n.showOnce ? 'repeatOnce' : 'repeatUntilDismissed';
    return '$title · ${context.tr(repeat)}';
  }

  void submit() {
    if (!formKey.currentState!.validate()) return;
    if (from != null && to != null && from!.isAfter(to!)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr('invalidDateRange'))));
      return;
    }
    String? trimmed(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    int? number(TextEditingController c) => int.tryParse(c.text.trim());
    Navigator.pop(context, <String, dynamic>{
      'text': text.text.trim(),
      'severity': int.parse(severity.text.trim()),
      'versionFrom': trimmed(versionFrom), 'versionTo': trimmed(versionTo),
      'userId': recipients == _Recipients.user ? trimmed(user) : null,
      'groupId': recipients == _Recipients.group ? groupId : null,
      'privilegeFrom': recipients == _Recipients.privilege ? number(privilegeFrom) : null,
      'privilegeTo': recipients == _Recipients.privilege ? number(privilegeTo) : null,
      'datetimeFrom': from?.toUtc().toIso8601String(), 'datetimeTo': to?.toUtc().toIso8601String(),
    });
  }

  Widget dateField(String label, DateTime? value, bool start) => ListTile(contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.schedule), title: Text(label),
    subtitle: Text(value == null ? context.tr('notSet') : formatDateTime(value)),
    onTap: () => pickDateTime(start),
    trailing: value == null ? null : IconButton(tooltip: context.tr('clear'), icon: const Icon(Icons.clear),
      onPressed: () => setState(() => start ? from = null : to = null)));

  Widget pair(Widget a, Widget b) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 12), Expanded(child: b)]);

  @override Widget build(BuildContext context) {
    final style = level == null ? null : notificationStyle(context, level!);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('createNotification'))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: Form(key: formKey, child: ListView(padding: const EdgeInsets.all(16), children: [
        TextFormField(controller: text, minLines: 3, maxLines: 8, maxLength: 5000,
          decoration: InputDecoration(labelText: context.tr('notificationText'), border: const OutlineInputBorder()),
          validator: (v) => (v ?? '').trim().isEmpty ? context.tr('fieldRequired') : null),
        const SizedBox(height: 8),
        TextFormField(controller: severity, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: context.tr('severity'), border: const OutlineInputBorder(),
            prefixIcon: style == null ? null : Icon(style.$1, color: style.$2),
            helperText: severityDescription(), helperMaxLines: 2),
          validator: (v) => numberValidator(v, required: true) ?? (int.parse(v!.trim()) < 0 ? context.tr('invalidNumber') : null)),
        Padding(padding: const EdgeInsets.only(top: 4, bottom: 16), child: Text(context.tr('severityHint'), style: Theme.of(context).textTheme.bodySmall)),
        DropdownButtonFormField<_Recipients>(initialValue: recipients, isExpanded: true,
          decoration: InputDecoration(labelText: context.tr('recipients'), border: const OutlineInputBorder()),
          items: [
            DropdownMenuItem(value: _Recipients.everyone, child: Text(context.tr('recipientsEveryone'))),
            DropdownMenuItem(value: _Recipients.user, child: Text(context.tr('recipientsUser'))),
            DropdownMenuItem(value: _Recipients.group, child: Text(context.tr('recipientsGroup'))),
            DropdownMenuItem(value: _Recipients.privilege, child: Text(context.tr('recipientsPrivilege'))),
          ], onChanged: (v) => setState(() => recipients = v!)),
        const SizedBox(height: 12),
        if (recipients == _Recipients.user) TextFormField(controller: user,
          decoration: InputDecoration(labelText: context.tr('userIdOrEmail'), border: const OutlineInputBorder()),
          validator: (v) => (v ?? '').trim().isEmpty ? context.tr('fieldRequired') : null),
        if (recipients == _Recipients.group) DropdownButtonFormField<String>(initialValue: groupId, isExpanded: true,
          decoration: InputDecoration(labelText: context.tr('assignGroup'), border: const OutlineInputBorder()),
          items: [for (final g in widget.groups) DropdownMenuItem(value: g.id,
            child: Text(g.privilege == null ? g.name : '${g.name} (${g.privilege})', overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => groupId = v),
          validator: (v) => v == null ? context.tr('fieldRequired') : null),
        if (recipients == _Recipients.privilege) pair(
          TextFormField(controller: privilegeFrom, keyboardType: TextInputType.number, validator: numberValidator,
            decoration: InputDecoration(labelText: context.tr('privilegeFrom'), border: const OutlineInputBorder())),
          TextFormField(controller: privilegeTo, keyboardType: TextInputType.number,
            validator: (v) => numberValidator(v) ?? (privilegeFrom.text.trim().isEmpty && (v ?? '').trim().isEmpty ? context.tr('fieldRequired') : null),
            decoration: InputDecoration(labelText: context.tr('privilegeTo'), border: const OutlineInputBorder()))),
        const SizedBox(height: 16),
        pair(
          TextFormField(controller: versionFrom, validator: versionValidator,
            decoration: InputDecoration(labelText: context.tr('versionFrom'), hintText: appVersion, border: const OutlineInputBorder())),
          TextFormField(controller: versionTo, validator: versionValidator,
            decoration: InputDecoration(labelText: context.tr('versionTo'), hintText: appVersion, border: const OutlineInputBorder()))),
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(context.tr('currentAppVersion', {'version': appVersion}), style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 8),
        dateField(context.tr('validFrom'), from, true),
        dateField(context.tr('validTo'), to, false),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: submit, icon: const Icon(Icons.campaign_outlined), label: Text(context.tr('create'))),
      ])))),
    );
  }
}
