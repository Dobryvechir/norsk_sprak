import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/l10n.dart';
import '../models/chat.dart';
import '../services/chat_api.dart';
import 'chat_conversation_screen.dart';
import 'chat_widgets.dart';

/// The people of a chat. Tapping someone offers a direct chat and, in a family chat, "Find location".
/// The owner of a subgroup invites members of its group here and can remove members.
class ChatMembersScreen extends StatefulWidget {
  final ChatApi chat; final ChatConversation conversation; final ChatPerson me;
  const ChatMembersScreen({super.key, required this.chat, required this.conversation, required this.me});
  @override State<ChatMembersScreen> createState() => _ChatMembersScreenState();
}

class _ChatMembersScreenState extends State<ChatMembersScreen> {
  late Future<List<ChatPerson>> future;
  ChatConversation get conv => widget.conversation;
  ChatApi get chat => widget.chat;

  @override void initState() { super.initState(); load(); }
  void load() => setState(() { future = chat.members(conv.id); });

  Future<void> invite(List<ChatPerson> current) async {
    final List<ChatPerson> candidates;
    try {
      final inSubgroup = {for (final p in current) p.id};
      candidates = (await chat.members('g-${conv.groupId}')).where((p) => !inSubgroup.contains(p.id)).toList();
    } catch (e) { if (mounted) showChatError(context, e); return; }
    if (!mounted) return;
    final chosen = <String>{};
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, update) => AlertDialog(
      title: Text(ctx.tr('chatInvite')),
      content: SizedBox(width: 380, child: candidates.isEmpty ? Text(ctx.tr('chatNobodyToInvite')) : ListView(shrinkWrap: true, children: [
        if (conv.family) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(ctx.tr('chatFamilyInfo'))),
        for (final p in candidates) CheckboxListTile(value: chosen.contains(p.id), title: Text(p.displayName),
          secondary: ChatAvatar(chat: chat, person: p),
          onChanged: (v) => update(() => v == true ? chosen.add(p.id) : chosen.remove(p.id))),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
        FilledButton(onPressed: chosen.isEmpty ? null : () => Navigator.pop(ctx, true), child: Text(ctx.tr('chatInvite'))),
      ])));
    if (ok != true || chosen.isEmpty) return;
    try { await chat.invite(conv.subgroupId, chosen.toList()); load(); }
    catch (e) { if (mounted) showChatError(context, e); }
  }

  Future<void> remove(ChatPerson p) async {
    try { await chat.removeMember(conv.subgroupId, p.id); load(); }
    catch (e) { if (mounted) showChatError(context, e); }
  }

  Future<void> directChat(ChatPerson p) async {
    try {
      final c = await chat.openDirect(conv.groupId, p.id);
      if (mounted) await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatConversationScreen(chat: chat, conversation: c, me: widget.me)));
    } catch (e) { if (mounted) showChatError(context, e); }
  }

  Future<void> actions(ChatPerson p) async {
    final choice = await showModalBottomSheet<String>(context: context, builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: ChatAvatar(chat: chat, person: p), title: Text(p.displayName, style: Theme.of(ctx).textTheme.titleMedium)),
      const Divider(height: 1),
      if (conv.family && !p.invited) ListTile(leading: const Icon(Icons.my_location), title: Text(ctx.tr('chatFindLocation')), onTap: () => Navigator.pop(ctx, 'location')),
      if (!conv.isDirect && !p.invited) ListTile(leading: const Icon(Icons.chat_bubble_outline), title: Text(ctx.tr('chatDirect')), onTap: () => Navigator.pop(ctx, 'direct')),
      if (conv.isSubgroup && conv.isOwner) ListTile(leading: const Icon(Icons.person_remove), title: Text(ctx.tr(p.invited ? 'chatWithdrawInvitation' : 'chatRemoveMember')),
        onTap: () => Navigator.pop(ctx, 'remove')),
    ])));
    if (!mounted) return;
    switch (choice) {
      case 'location': await showDialog<void>(context: context, builder: (_) => _LocationDialog(chat: chat, conversationId: conv.id, person: p));
      case 'direct': await directChat(p);
      case 'remove': await remove(p);
    }
  }

  @override Widget build(BuildContext context) => FutureBuilder<List<ChatPerson>>(future: future, builder: (ctx, snap) {
    final people = snap.data;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('chatMembersOf', {'name': conv.name})), actions: [
        IconButton(tooltip: context.tr('refresh'), onPressed: load, icon: const Icon(Icons.refresh))]),
      floatingActionButton: conv.isSubgroup && conv.isOwner && people != null
        ? FloatingActionButton.extended(onPressed: () => invite(people), icon: const Icon(Icons.person_add), label: Text(context.tr('chatInvite')))
        : null,
      body: people == null
        ? Center(child: snap.hasError ? Text('${snap.error}') : const CircularProgressIndicator())
        : Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
            if (conv.family) Padding(padding: const EdgeInsets.all(12), child: Text(context.tr('chatFamilyInfo'))),
            for (final p in people) ListTile(leading: ChatAvatar(chat: chat, person: p), title: Text(p.displayName),
              subtitle: p.owner || p.invited || p.id == widget.me.id ? Text([
                if (p.id == widget.me.id) context.tr('chatYou'), if (p.owner) context.tr('chatOwner'), if (p.invited) context.tr('chatInvited'),
              ].join(' · ')) : null,
              trailing: p.id == widget.me.id ? null : const Icon(Icons.more_vert),
              onTap: p.id == widget.me.id ? null : () => actions(p)),
          ]))),
    );
  });
}

/// "Find location": asks [person]'s app for its location, shows the last one known meanwhile and the
/// fresh one when it arrives, with a button to open it in Google Maps.
class _LocationDialog extends StatefulWidget {
  final ChatApi chat; final String conversationId; final ChatPerson person;
  const _LocationDialog({required this.chat, required this.conversationId, required this.person});
  @override State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  static const checks = 12, every = Duration(seconds: 5);
  ChatLocation? location;
  DateTime? asked;
  bool waiting = true;
  String? error;
  Timer? timer;

  @override void initState() { super.initState(); start(); }
  @override void dispose() { timer?.cancel(); super.dispose(); }

  Future<void> start() async {
    timer?.cancel();
    setState(() { waiting = true; error = null; });
    try {
      asked = DateTime.now();
      final last = await widget.chat.requestLocation(widget.conversationId, widget.person.id);
      if (!mounted) return;
      setState(() => location = last);
      var count = 0;
      timer = Timer.periodic(every, (t) async {
        count++;
        try {
          final l = await widget.chat.location(widget.conversationId, widget.person.id);
          if (!mounted) return;
          final fresh = l != null && asked != null && l.updatedAt.isAfter(asked!.subtract(const Duration(seconds: 2)));
          setState(() { if (l != null) location = l; if (fresh || count >= checks) { waiting = false; t.cancel(); } });
        } catch (_) { if (count >= checks) { t.cancel(); if (mounted) setState(() => waiting = false); } }
      });
    } catch (e) { if (mounted) setState(() { error = '$e'; waiting = false; }); }
  }

  Future<void> openMap() async {
    final l = location; if (l == null) return;
    var ok = false;
    try { ok = await launchUrl(l.mapsUrl, mode: LaunchMode.externalApplication); } catch (_) {}
    if (!ok && mounted) showChatError(context, trNow('linkOpenFailed', {'url': l.mapsUrl}));
  }

  @override Widget build(BuildContext context) {
    final l = location;
    return AlertDialog(
      title: Text(context.tr('chatLocationOf', {'name': widget.person.displayName})),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
        else if (l == null) Text(context.tr(waiting ? 'chatLocationWaiting' : 'chatLocationUnknown'))
        else ...[
          SelectableText('${l.lat.toStringAsFixed(6)}, ${l.lng.toStringAsFixed(6)}', style: Theme.of(context).textTheme.titleMedium),
          if (l.accuracy != null) Text(context.tr('chatLocationAccuracy', {'meters': l.accuracy!.round()})),
          Text(context.tr('chatLocationTime', {'time': chatTime(l.updatedAt)})),
        ],
        if (waiting) ...[const SizedBox(height: 12), const LinearProgressIndicator(), const SizedBox(height: 4), Text(context.tr('chatLocationWaiting'))],
        if (!waiting && l != null && asked != null && l.updatedAt.isBefore(asked!)) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(context.tr('chatLocationOld'))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('close'))),
        if (!waiting) TextButton(onPressed: start, child: Text(context.tr('refresh'))),
        FilledButton.icon(onPressed: l == null ? null : openMap, icon: const Icon(Icons.map), label: Text(context.tr('chatOpenMap'))),
      ],
    );
  }
}
