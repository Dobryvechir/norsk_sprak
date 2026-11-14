import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
/// System admin: review people who signed up and approve (optionally straight
/// into a group - the "Basic" group is suggested) or reject them. Each request
/// shows whether the email is verified and which plan was chosen; people who
/// paid for Pro become users (in the "Advanced" group) without appearing here. Decided requests disappear from the list;
/// approved users can later be added to groups from each group's admin screen.
class SignupRequestsScreen extends StatefulWidget {
  final Api api;
  const SignupRequestsScreen({super.key, required this.api});
  @override State<SignupRequestsScreen> createState() => _SignupRequestsScreenState();
}
class _SignupRequestsScreenState extends State<SignupRequestsScreen> {
  late Future<List<SignupCandidate>> future;
  List<StudyGroup> groups = const [];
  @override void initState() { super.initState(); refresh(); loadGroups(); }
  void refresh() => setState(() { future = widget.api.signupCandidates(); });
  Future<void> loadGroups() async {
    try { final list = await widget.api.groups(); if (mounted) setState(() => groups = list); } catch (e) { showError(e); }
  }
  void showError(Object e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
  void showMessage(String text) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text))); }
  String formatDate(DateTime? d) => d == null ? '' :
    '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Group (or "no group for now") + role picker shown when approving.
  Future<(String?, String)?> pickGroup(String title, {String? suggested}) {
    String? groupId = groups.any((g) => g.id == suggested) ? suggested : null;
    String role = 'viewer';
    return showDialog<(String?, String)>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, update) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String?>(initialValue: groupId, isExpanded: true, decoration: InputDecoration(labelText: context.tr('assignGroup')),
          items: [
            DropdownMenuItem<String?>(value: null, child: Text(context.tr('noGroupYet'))),
            for (final g in groups) DropdownMenuItem<String?>(value: g.id, child: Text(g.name, overflow: TextOverflow.ellipsis)),
          ], onChanged: (v) => update(() => groupId = v)),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(initialValue: role, isExpanded: true, decoration: InputDecoration(labelText: context.tr('roleLabel')),
          items: ['viewer', 'uploader', 'admin'].map((x) => DropdownMenuItem(value: x, child: Text(context.trRole(x)))).toList(),
          onChanged: groupId == null ? null : (v) => update(() => role = v!)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, (groupId, role)),
          child: Text(context.tr('approve')))],
    )));
  }
  String groupName(String id) => groups.firstWhere((g) => g.id == id, orElse: () => StudyGroup(id, id)).name;

  Future<void> approve(SignupCandidate c) async {
    final choice = await pickGroup(context.tr('approveSignupTitle', {'email': c.email}), suggested: c.defaultGroupId);
    if (choice == null) return;
    try {
      await widget.api.approveCandidate(c.id, groupId: choice.$1, role: choice.$2);
      if (choice.$1 != null && mounted) showMessage(context.tr('userAddedToGroup', {'email': c.email, 'group': groupName(choice.$1!)}));
      refresh();
    } catch (e) { showError(e); }
  }
  Future<void> reject(SignupCandidate c) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      content: Text(context.tr('rejectSignupConfirm', {'email': c.email})),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.tr('reject')))]));
    if (ok != true) return;
    try { await widget.api.rejectCandidate(c.id); refresh(); } catch (e) { showError(e); }
  }
  static const paymentMethods = {'vipps': 'Vipps', 'googlepay': 'Google Pay', 'applepay': 'Apple Pay'};
  Widget chip(String text, Color color, {IconData? icon}) => Chip(
    avatar: icon == null ? null : Icon(icon, size: 16, color: color),
    label: Text(text), labelStyle: TextStyle(color: color), side: BorderSide(color: color),
    visualDensity: VisualDensity.compact);
  Widget card(SignupCandidate c) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final ok = Colors.green.shade700, muted = theme.colorScheme.outline;
    final plan = switch (c.plan) {
      'basic' => chip(context.tr('planBasic'), color),
      'pro' when c.paymentStatus == 'paid' => chip(context.tr('planProPaid', {'method': paymentMethods[c.paymentMethod] ?? '${c.paymentMethod}'}), ok),
      'pro' => chip(context.tr('planProNotPaid'), theme.colorScheme.error),
      _ => null,
    };
    return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: SelectableText(c.email, style: theme.textTheme.titleMedium)),
        Chip(label: Text(context.tr('signupPending')), labelStyle: TextStyle(color: color), side: BorderSide(color: color), visualDensity: VisualDensity.compact),
      ]),
      Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 8, runSpacing: 4, children: [
        c.emailVerified
          ? chip(context.tr('emailVerified'), ok, icon: Icons.verified)
          : chip(context.tr('emailNotVerified'), muted, icon: Icons.mark_email_unread_outlined),
        if (plan != null) plan,
      ])),
      if (c.info.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: SelectableText(context.tr('signupInfo', {'info': c.info}))),
      Padding(padding: const EdgeInsets.only(top: 6), child: Text(context.tr('signupMeta', {'ip': c.ip, 'browser': c.browser, 'date': formatDate(c.createdAt)}),
        style: theme.textTheme.bodySmall)),
      Padding(padding: const EdgeInsets.only(top: 8),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(onPressed: () => approve(c), icon: const Icon(Icons.check), label: Text(context.tr('approve'))),
          OutlinedButton.icon(onPressed: () => reject(c), icon: const Icon(Icons.close), label: Text(context.tr('reject'))),
        ])),
    ])));
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('signupRequests')), actions: [IconButton(tooltip: context.tr('refresh'), onPressed: refresh, icon: const Icon(Icons.refresh))]),
    body: FutureBuilder<List<SignupCandidate>>(future: future, builder: (ctx, snap) {
      if (!snap.hasData) return Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator());
      final list = snap.data!; // only undecided requests, newest first
      if (list.isEmpty) return Center(child: Text(context.tr('noSignupRequests')));
      return RefreshIndicator(onRefresh: () async { refresh(); await future; },
        child: ListView(padding: const EdgeInsets.all(12), children: [for (final c in list) card(c)]));
    }),
  );
}
