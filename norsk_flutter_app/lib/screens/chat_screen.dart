import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/chat.dart';
import '../services/api.dart';
import '../services/chat_api.dart';
import 'chat_conversation_screen.dart';
import 'chat_profile_screen.dart';
import 'chat_widgets.dart';

/// Chat: a search field for people (only those sharing a non-anonymous group), invitations to
/// subgroups, and every chat the user takes part in: one per non-anonymous group, their subgroups and
/// their direct chats. A photo is required first (see [ChatProfileScreen]).
class ChatScreen extends StatefulWidget {
  final Api api;
  const ChatScreen({super.key, required this.api});
  @override State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final chat = ChatApi(widget.api);
  final search = TextEditingController();
  ChatStatus? status;
  List<ChatConversation> conversations = const [];
  List<ChatInvitation> invitations = const [];
  List<ChatPerson>? found;
  Object? error;
  bool loading = true;
  Timer? debounce, poll;

  @override void initState() {
    super.initState();
    load();
    poll = Timer.periodic(const Duration(seconds: 30), (_) => load(quiet: true));
  }
  @override void dispose() { debounce?.cancel(); poll?.cancel(); search.dispose(); super.dispose(); }

  Future<void> load({bool quiet = false}) async {
    if (!quiet) setState(() { loading = true; error = null; });
    try {
      final s = await chat.status();
      final results = s.hasPhoto ? await Future.wait([chat.conversations(), chat.invitations()]) : const [<ChatConversation>[], <ChatInvitation>[]];
      if (!mounted) return;
      setState(() {
        status = s;
        conversations = (results[0] as List<ChatConversation>)..sort(_order);
        invitations = results[1] as List<ChatInvitation>;
        loading = false; error = null;
      });
    } catch (e) { if (mounted && !quiet) setState(() { error = e; loading = false; }); }
  }

  /// Groups first, then subgroups, then direct chats; within each the most recently active first.
  static int _order(ChatConversation a, ChatConversation b) {
    int rank(ChatConversation c) => c.isGroup ? 0 : c.isSubgroup ? 1 : 2;
    final byType = rank(a).compareTo(rank(b));
    if (byType != 0) return byType;
    final byTime = (b.lastAt ?? '').compareTo(a.lastAt ?? '');
    return byTime != 0 ? byTime : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  void onSearch(String text) {
    debounce?.cancel();
    setState(() { if (text.trim().length < 2) found = null; }); // also shows/hides the clear button
    if (text.trim().length < 2) return;
    debounce = Timer(const Duration(milliseconds: 400), () async {
      try { final people = await chat.searchUsers(text.trim()); if (mounted && search.text == text) setState(() => found = people); }
      catch (e) { if (mounted) showChatError(context, e); }
    });
  }

  Future<void> editProfile() async {
    final s = status; if (s == null) return;
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => ChatProfileScreen(chat: chat, status: s)));
    if (saved == true) load();
  }

  Future<void> open(ChatConversation c) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatConversationScreen(chat: chat, conversation: c, me: status!)));
    load(quiet: true);
  }

  /// A direct chat with [person]; when several groups are shared, the user picks the group it belongs to.
  Future<void> message(ChatPerson person) async {
    var groupId = person.groups.isEmpty ? null : person.groups.first.$1;
    if (person.groups.length > 1) {
      groupId = await showDialog<String>(context: context, builder: (ctx) => SimpleDialog(title: Text(ctx.tr('chatChooseGroup')), children: [
        for (final (id, name) in person.groups) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, id), child: Text(name)),
      ]));
    }
    if (groupId == null) return;
    try { final c = await chat.openDirect(groupId, person.id); search.clear(); setState(() => found = null); await open(c); }
    catch (e) { if (mounted) showChatError(context, e); }
  }

  Future<void> respond(ChatInvitation inv, bool yes) async {
    try {
      if (yes) { final c = await chat.accept(inv.id); await load(); if (mounted) await open(c); }
      else { await chat.decline(inv.id); await load(); }
    } catch (e) { if (mounted) showChatError(context, e); }
  }

  Future<void> createSubgroup() async {
    final groups = conversations.where((c) => c.isGroup).toList();
    if (groups.isEmpty) return;
    final name = TextEditingController();
    var groupId = groups.first.groupId; var family = false;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, update) => AlertDialog(
      title: Text(ctx.tr('chatNewSubgroup')),
      content: SizedBox(width: 380, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(initialValue: groupId, isExpanded: true, decoration: InputDecoration(labelText: ctx.tr('chatInGroup')),
          items: [for (final g in groups) DropdownMenuItem(value: g.groupId, child: Text(g.name))],
          onChanged: (v) => update(() => groupId = v ?? groupId)),
        TextField(controller: name, autofocus: true, maxLength: 100, decoration: InputDecoration(labelText: ctx.tr('chatSubgroupName'))),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: family, onChanged: (v) => update(() => family = v),
          title: Text(ctx.tr('chatFamily')), subtitle: Text(ctx.tr('chatFamilyInfo'))),
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('create'))),
      ])));
    final text = name.text.trim();
    name.dispose();
    if (ok != true || text.isEmpty) return;
    try { final c = await chat.createSubgroup(groupId, text, family); await load(); if (mounted) await open(c); }
    catch (e) { if (mounted) showChatError(context, e); }
  }

  @override Widget build(BuildContext context) {
    final s = status;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('menuChat')), actions: [
        if (s != null && s.hasPhoto) IconButton(tooltip: context.tr('chatProfile'), onPressed: editProfile,
          icon: ChatAvatar(chat: chat, person: s, radius: 14)),
        IconButton(tooltip: context.tr('refresh'), onPressed: load, icon: const Icon(Icons.refresh)),
      ]),
      floatingActionButton: s != null && s.hasPhoto && conversations.any((c) => c.isGroup)
        ? FloatingActionButton.extended(onPressed: createSubgroup, icon: const Icon(Icons.group_add), label: Text(context.tr('chatNewSubgroup')))
        : null,
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: body(context))),
    );
  }

  Widget body(BuildContext context) {
    final s = status;
    if (loading && s == null) return const Center(child: CircularProgressIndicator());
    if (error != null && s == null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(readableError(error!), textAlign: TextAlign.center), const SizedBox(height: 16),
        FilledButton.icon(onPressed: load, icon: const Icon(Icons.refresh), label: Text(context.tr('refresh'))),
      ])));
    }
    if (!s!.hasPhoto) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.account_circle, size: 96), const SizedBox(height: 12),
        Text(context.tr('chatPhotoRequired'), textAlign: TextAlign.center), const SizedBox(height: 16),
        FilledButton.icon(onPressed: editProfile, icon: const Icon(Icons.add_a_photo), label: Text(context.tr('chatProfile'))),
      ])));
    }
    final people = found;
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: TextField(controller: search, onChanged: onSearch,
        decoration: InputDecoration(hintText: context.tr('chatSearch'), prefixIcon: const Icon(Icons.search), border: const OutlineInputBorder(),
          suffixIcon: search.text.isEmpty ? null : IconButton(tooltip: context.tr('close'), icon: const Icon(Icons.clear),
            onPressed: () { search.clear(); setState(() => found = null); })))),
      Expanded(child: RefreshIndicator(onRefresh: load, child: ListView(padding: const EdgeInsets.only(bottom: 88), children: people != null ? [
        if (people.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(context.tr('chatNoPeople'), textAlign: TextAlign.center)),
        for (final p in people) ListTile(leading: ChatAvatar(chat: chat, person: p), title: Text(p.displayName),
          subtitle: Text(p.groups.map((g) => g.$2).join(', ')), trailing: const Icon(Icons.chat_bubble_outline), onTap: () => message(p)),
      ] : [
        for (final inv in invitations) Card(margin: const EdgeInsets.fromLTRB(12, 4, 12, 4), color: Theme.of(context).colorScheme.secondaryContainer,
          child: ListTile(leading: Icon(inv.family ? Icons.family_restroom : Icons.mail_outline),
            title: Text(context.tr('chatInvitation', {'name': inv.name})),
            subtitle: Text(context.tr(inv.family ? 'chatInvitationFamily' : 'chatInvitationFrom', {'person': inv.invitedBy.displayName, 'group': inv.groupName})),
            trailing: Wrap(children: [
              IconButton(tooltip: context.tr('chatDecline'), onPressed: () => respond(inv, false), icon: const Icon(Icons.close)),
              IconButton(tooltip: context.tr('chatAccept'), onPressed: () => respond(inv, true), icon: const Icon(Icons.check)),
            ]))),
        if (conversations.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(context.tr('chatNoChats'), textAlign: TextAlign.center)),
        for (final c in conversations) ListTile(leading: CircleAvatar(child: Icon(conversationIcon(c))), title: Text(c.name),
          subtitle: Text([
            if (c.isGroup) context.tr('chatGroupChat') else c.groupName,
            if (c.family) context.tr('chatFamily'),
            if (c.lastAt != null) chatTime(DateTime.tryParse(c.lastAt!)?.toLocal() ?? DateTime.now()),
          ].join(' · ')),
          trailing: const Icon(Icons.chevron_right), onTap: () => open(c)),
      ]))),
    ]);
  }
}
