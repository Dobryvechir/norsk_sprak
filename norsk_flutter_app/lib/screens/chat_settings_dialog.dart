import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/chat.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/chat_api.dart';

/// Lets a group admin change the group's chat settings: anonymous, family and the limits.
Future<void> showChatSettingsDialog(BuildContext context, Api api, StudyGroup group) =>
  showDialog<void>(context: context, builder: (_) => _ChatSettingsDialog(chat: ChatApi(api), group: group));

class _ChatSettingsDialog extends StatefulWidget {
  final ChatApi chat; final StudyGroup group;
  const _ChatSettingsDialog({required this.chat, required this.group});
  @override State<_ChatSettingsDialog> createState() => _ChatSettingsDialogState();
}

class _ChatSettingsDialogState extends State<_ChatSettingsDialog> {
  final subgroups = TextEditingController(), kb = TextEditingController(), days = TextEditingController();
  bool anonymous = false, family = false, loading = true, saving = false;
  String? error;

  @override void initState() { super.initState(); load(); }
  @override void dispose() { subgroups.dispose(); kb.dispose(); days.dispose(); super.dispose(); }

  Future<void> load() async {
    setState(() { loading = true; error = null; });
    try {
      final s = await widget.chat.groupSettings(widget.group.id);
      if (!mounted) return;
      setState(() {
        anonymous = s.anonymous; family = s.family;
        subgroups.text = '${s.subgroupLimitPerYear}'; kb.text = '${s.chatPerDayKb}'; days.text = '${s.expirationDays}';
        loading = false;
      });
    } catch (e) { if (mounted) setState(() { error = readableError(e); loading = false; }); }
  }

  /// The number in [c] if it is a whole number from [min] to [max] (the server's limits), else null.
  static int? number(TextEditingController c, int min, int max) {
    final n = int.tryParse(c.text.trim());
    return n != null && n >= min && n <= max ? n : null;
  }

  Future<void> save() async {
    final s = number(subgroups, 0, 10000), k = number(kb, 1, 100000), d = number(days, 1, 3650);
    if (s == null || k == null || d == null) { setState(() => error = context.tr('chatSettingsInvalid')); return; }
    setState(() { saving = true; error = null; });
    try {
      await widget.chat.saveGroupSettings(widget.group.id, GroupChatSettings(anonymous: anonymous, family: family,
        subgroupLimitPerYear: s, chatPerDayKb: k, expirationDays: d));
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text(trNow('chatSettingsSaved'))));
    } catch (e) { if (mounted) setState(() { saving = false; error = readableError(e); }); }
  }

  @override Widget build(BuildContext context) {
    Widget numberField(TextEditingController c, String key) => Padding(padding: const EdgeInsets.only(top: 12),
      child: TextField(controller: c, enabled: !saving, keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: context.tr(key), border: const OutlineInputBorder(), isDense: true)));
    return AlertDialog(
      title: Text('${context.tr('chatSettings')}: ${widget.group.name}'),
      content: SizedBox(width: 400, child: loading ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
        : SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SwitchListTile(contentPadding: EdgeInsets.zero, value: anonymous, onChanged: saving ? null : (v) => setState(() => anonymous = v),
              title: Text(context.tr('chatAnonymous')), subtitle: Text(context.tr('chatAnonymousInfo'))),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: family, onChanged: saving ? null : (v) => setState(() => family = v),
              title: Text(context.tr('chatFamily')), subtitle: Text(context.tr('chatFamilyInfo'))),
            numberField(subgroups, 'chatSubgroupLimit'),
            numberField(kb, 'chatPerDayKb'),
            numberField(days, 'chatExpirationDays'),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ]))),
      actions: [
        TextButton(onPressed: saving ? null : () => Navigator.pop(context), child: Text(context.tr('cancel'))),
        if (!loading && error != null && subgroups.text.isEmpty)
          TextButton(onPressed: load, child: Text(context.tr('refresh')))
        else FilledButton(onPressed: loading || saving ? null : save, child: Text(context.tr('save'))),
      ],
    );
  }
}
