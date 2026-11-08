import 'dart:async';
import 'package:dio/dio.dart' show ProgressCallback;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../l10n/l10n.dart';
import '../models/chat.dart';
import '../services/chat_api.dart';
import '../services/google_drive.dart';
import '../services/media_store.dart';
import '../services/settings.dart';
import 'audio_record_screen.dart';
import 'camera_capture_screen.dart';
import 'chat_members_screen.dart';
import 'chat_widgets.dart';
import 'media_list_screen.dart';
import 'media_view_screen.dart' show extensionFor;

/// One chat: its messages (checked for new ones every few seconds) and a field to write. Pictures,
/// audio, video and files are uploaded to the sender's own Google Drive (folder `chat`, or taken from
/// Media), shared "anyone with the link", and only the link is sent to our server. That needs the
/// Google Drive connected in Settings.
class ChatConversationScreen extends StatefulWidget {
  final ChatApi chat; final ChatConversation conversation; final ChatPerson me;
  const ChatConversationScreen({super.key, required this.chat, required this.conversation, required this.me});
  @override State<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends State<ChatConversationScreen> {
  static const pollEvery = Duration(seconds: 4);
  final drive = GoogleDrive();
  final input = TextEditingController();
  final messages = <ChatMessage>[];
  /// Members by id, for names and photos.
  var people = <String, ChatPerson>{};
  Timer? poll;
  bool loading = true, sending = false, polling = false;
  String? error;

  ChatConversation get conv => widget.conversation;
  ChatApi get chat => widget.chat;
  bool get canAttach => AppSettings.instance.driveConnected;

  @override void initState() {
    super.initState();
    loadMembers();
    refresh();
    poll = Timer.periodic(pollEvery, (_) => refresh());
  }
  @override void dispose() { poll?.cancel(); input.dispose(); MediaTemp.clearAll(); super.dispose(); }

  Future<void> loadMembers() async {
    try {
      final list = await chat.members(conv.id);
      if (mounted) setState(() => people = {for (final m in list) m.id: m});
    } catch (_) {}
  }

  /// Fetches the messages newer than the last one shown.
  Future<void> refresh() async {
    if (polling) return;
    polling = true;
    try {
      final fresh = await chat.messages(conv.id, since: messages.isEmpty ? null : messages.last.createdAt);
      if (!mounted) return;
      final known = {for (final m in messages) m.id};
      setState(() { messages.addAll(fresh.where((m) => !known.contains(m.id))); loading = false; error = null; });
      if (fresh.any((m) => !people.containsKey(m.senderId))) loadMembers();
    } catch (e) {
      if (mounted) setState(() { loading = false; error = '$e'; });
    } finally { polling = false; }
  }

  Future<void> send({List<ChatAttachment> attachments = const []}) async {
    final text = input.text.trim();
    if (text.isEmpty && attachments.isEmpty) return;
    setState(() => sending = true);
    try {
      await chat.send(conv.id, text, attachments);
      input.clear();
      await refresh();
    } catch (e) { if (mounted) showChatError(context, e); }
    finally { if (mounted) setState(() => sending = false); }
  }

  // ----- Attachments -----

  /// Uploads with [upload] into the Drive folder `chat` while a progress dialog is shown over [context],
  /// shares the file with anyone who has the link, and sends the link.
  Future<void> shareUpload(BuildContext context, AttachmentKind kind, String name, String mimeType, int? size,
      Future<String> Function(String folderId, ProgressCallback onProgress) upload) async {
    final progress = ValueNotifier<double?>(null);
    final navigator = Navigator.of(context);
    unawaited(showDialog<void>(context: context, barrierDismissible: false, builder: (ctx) => PopScope(canPop: false, child: AlertDialog(
      title: Text(ctx.tr('chatUploading')),
      content: ValueListenableBuilder<double?>(valueListenable: progress, builder: (_, v, __) => LinearProgressIndicator(value: v))))));
    ChatAttachment? attachment;
    try {
      final id = await upload(await drive.chatFolder(), (sent, total) { if (total > 0) progress.value = sent / total; });
      progress.value = null;
      attachment = ChatAttachment(kind, name, await drive.shareWithAnyone(id), driveId: id, mimeType: mimeType, size: size);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text(e is DriveException ? e.message : '$e')));
    } finally { navigator.pop(); }
    if (attachment != null) await send(attachments: [attachment]);
  }

  static String stamp() {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  static AttachmentKind kindOf(String mimeType) => mimeType.startsWith('image/') ? AttachmentKind.picture
    : mimeType.startsWith('audio/') ? AttachmentKind.audio : mimeType.startsWith('video/') ? AttachmentKind.video : AttachmentKind.file;

  /// A media type from the file name; unknown ones are sent as plain files.
  static String mimeTypeOfFile(String name) {
    const other = 'application/octet-stream';
    final ext = p.extension(name).toLowerCase();
    if (ext == '.pdf') return 'application/pdf';
    if (ext == '.gif') return 'image/gif';
    for (final kind in MediaKind.values) {
      final type = mimeTypeFor(name, kind);
      if (type != kind.defaultMimeType || extensionFor(type) == ext) return type;
    }
    return other;
  }

  Future<void> uploadFile() async {
    final result = await FilePicker.platform.pickFiles(withData: kIsWeb);
    final f = result?.files.single;
    if (f == null || !mounted) return;
    final type = mimeTypeOfFile(f.name);
    await shareUpload(context, kindOf(type), f.name, type, f.size, (folder, onProgress) => f.path != null && !kIsWeb
      ? drive.uploadFile(folder, f.name, type, f.path!, onProgress: onProgress)
      : drive.uploadBytes(folder, f.name, type, f.bytes!, onProgress: onProgress));
  }

  /// Sends a picture, video or audio just captured: [context] is the capture screen's.
  Future<void> sendCaptured(BuildContext context, LocalMedia media, Duration? _) async {
    final kind = switch (media.kind) { MediaKind.picture => AttachmentKind.picture, MediaKind.video => AttachmentKind.video, MediaKind.audio => AttachmentKind.audio };
    final name = '${media.kind.name}_${stamp()}${extensionFor(media.mimeType)}';
    final size = await media.length();
    if (context.mounted) {
      await shareUpload(context, kind, name, media.mimeType, size,
        (folder, onProgress) => drive.uploadMedia(folder, name, media, onProgress: onProgress));
    }
    await media.delete();
  }

  void capture(Widget screen) => Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => screen));

  Future<void> fromMedia(MediaKind kind) async {
    final file = await Navigator.push<DriveFile>(context, MaterialPageRoute(builder: (_) => MediaListScreen(drive: drive, kind: kind, picking: true)));
    if (file == null || !mounted) return;
    final type = file.mimeType.isEmpty ? kind.defaultMimeType : file.mimeType;
    await shareUpload(context, kindOf(type), file.name, type, file.size, (_, __) async => file.id);
  }

  Future<void> attach() async {
    if (!canAttach) { showChatError(context, trNow('chatDriveNeeded')); return; }
    final choice = await showModalBottomSheet<String>(context: context, builder: (ctx) => SafeArea(child: ListView(shrinkWrap: true, children: [
      ListTile(leading: const Icon(Icons.upload_file), title: Text(ctx.tr('docUpload')), onTap: () => Navigator.pop(ctx, 'file')),
      ListTile(leading: const Icon(Icons.photo_camera), title: Text(ctx.tr('mediaNewPicture')), onTap: () => Navigator.pop(ctx, 'picture')),
      ListTile(leading: const Icon(Icons.videocam), title: Text(ctx.tr('mediaNewVideo')), onTap: () => Navigator.pop(ctx, 'video')),
      ListTile(leading: const Icon(Icons.mic), title: Text(ctx.tr('mediaNewAudio')), onTap: () => Navigator.pop(ctx, 'audio')),
      const Divider(),
      ListTile(leading: const Icon(Icons.photo_library), title: Text(ctx.tr('chatFromMedia', {'kind': ctx.tr('mediaPictures')})), onTap: () => Navigator.pop(ctx, 'mediaPicture')),
      ListTile(leading: const Icon(Icons.video_library), title: Text(ctx.tr('chatFromMedia', {'kind': ctx.tr('mediaVideos')})), onTap: () => Navigator.pop(ctx, 'mediaVideo')),
      ListTile(leading: const Icon(Icons.library_music), title: Text(ctx.tr('chatFromMedia', {'kind': ctx.tr('mediaAudio')})), onTap: () => Navigator.pop(ctx, 'mediaAudio')),
    ])));
    switch (choice) {
      case 'file': await uploadFile();
      case 'picture': capture(CameraCaptureScreen(kind: MediaKind.picture, onCaptured: sendCaptured));
      case 'video': capture(CameraCaptureScreen(kind: MediaKind.video, onCaptured: sendCaptured));
      case 'audio': capture(AudioRecordScreen(onCaptured: sendCaptured));
      case 'mediaPicture': await fromMedia(MediaKind.picture);
      case 'mediaVideo': await fromMedia(MediaKind.video);
      case 'mediaAudio': await fromMedia(MediaKind.audio);
    }
  }

  // ----- Subgroup actions -----

  Future<void> leaveOrDelete() async {
    final owner = conv.isOwner;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(ctx.tr(owner ? 'chatDeleteSubgroupQuestion' : 'chatLeaveQuestion', {'name': conv.name})),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr(owner ? 'delete' : 'chatLeave'))),
      ]));
    if (ok != true) return;
    try {
      owner ? await chat.deleteSubgroup(conv.subgroupId) : await chat.leave(conv.subgroupId);
      if (mounted) Navigator.pop(context);
    } catch (e) { if (mounted) showChatError(context, e); }
  }

  Future<void> openMembers() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatMembersScreen(chat: chat, conversation: conv, me: widget.me)));
    loadMembers();
  }

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = messages.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(conv.name, overflow: TextOverflow.ellipsis),
          Text([conv.isGroup ? context.tr('chatGroupChat') : conv.groupName, if (conv.family) context.tr('chatFamily')].join(' · '),
            style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
        ]),
        actions: [
          IconButton(tooltip: context.tr('chatMembers'), onPressed: openMembers, icon: Icon(conv.family ? Icons.family_restroom : Icons.people)),
          if (conv.isSubgroup) PopupMenuButton<String>(onSelected: (_) => leaveOrDelete(), itemBuilder: (ctx) => [
            PopupMenuItem(value: 'x', child: Text(ctx.tr(conv.isOwner ? 'chatDeleteSubgroup' : 'chatLeave'))),
          ]),
        ]),
      body: SafeArea(child: Column(children: [
        if (error != null && messages.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(error!, style: TextStyle(color: theme.colorScheme.error))),
        Expanded(child: loading ? const Center(child: CircularProgressIndicator())
          : messages.isEmpty ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(context.tr('chatNoMessages'), textAlign: TextAlign.center)))
          : ListView.builder(reverse: true, padding: const EdgeInsets.all(8), itemCount: shown.length, itemBuilder: (_, i) {
              final m = shown[i];
              final next = i + 1 < shown.length ? shown[i + 1] : null; // the one before it in time
              return _Bubble(chat: chat, message: m, mine: m.senderId == widget.me.id,
                sender: people[m.senderId] ?? ChatPerson(m.senderId, '…'), showSender: next?.senderId != m.senderId);
            })),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.fromLTRB(4, 4, 4, 4), child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          IconButton(tooltip: context.tr(canAttach ? 'chatAttach' : 'chatDriveNeeded'), onPressed: sending ? null : attach,
            icon: Icon(Icons.attach_file, color: canAttach ? null : theme.disabledColor)),
          Expanded(child: TextField(controller: input, minLines: 1, maxLines: 5, maxLength: 4000, textInputAction: TextInputAction.newline,
            decoration: InputDecoration(hintText: context.tr('chatWrite'), counterText: '', border: const OutlineInputBorder(), isDense: true))),
          IconButton(tooltip: context.tr('chatSend'), onPressed: sending ? null : () => send(),
            icon: sending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send)),
        ])),
      ])),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatApi chat; final ChatMessage message; final ChatPerson sender; final bool mine, showSender;
  const _Bubble({required this.chat, required this.message, required this.sender, required this.mine, required this.showSender});

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 420),
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(color: mine ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (!mine && showSender) Text(sender.displayName, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
        for (final a in message.attachments) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _AttachmentView(attachment: a)),
        if (message.text.isNotEmpty) SelectableText(message.text),
        Align(alignment: Alignment.bottomRight, child: Text(chatTime(message.time), style: theme.textTheme.labelSmall)),
      ]));
    return Row(mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start, crossAxisAlignment: CrossAxisAlignment.end, children: [
      if (!mine) SizedBox(width: 40, child: showSender ? ChatAvatar(chat: chat, person: sender, radius: 16) : null),
      Flexible(child: bubble),
    ]);
  }
}

/// A link to a file on Google Drive: pictures show a preview; a tap opens the file (Drive's viewer).
class _AttachmentView extends StatelessWidget {
  final ChatAttachment attachment;
  const _AttachmentView({required this.attachment});

  Future<void> open(BuildContext context) async {
    var ok = false;
    try { ok = await launchUrl(Uri.parse(attachment.url), mode: LaunchMode.externalApplication); } catch (_) {}
    if (!ok && context.mounted) showChatError(context, trNow('linkOpenFailed', {'url': attachment.url}));
  }

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (attachment.kind) {
      AttachmentKind.picture => Icons.image, AttachmentKind.audio => Icons.audiotrack,
      AttachmentKind.video => Icons.movie, AttachmentKind.file => Icons.insert_drive_file };
    final tile = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: theme.colorScheme.primary), const SizedBox(width: 8),
      Flexible(child: Text(attachment.name, style: const TextStyle(decoration: TextDecoration.underline), overflow: TextOverflow.ellipsis)),
      const SizedBox(width: 4), const Icon(Icons.open_in_new, size: 16),
    ]);
    final thumb = attachment.thumbnailUrl;
    return InkWell(onTap: () => open(context), child: attachment.kind == AttachmentKind.picture && thumb != null
      ? Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 260),
            child: Image.network(thumb, fit: BoxFit.contain, webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              loadingBuilder: (_, child, progress) => progress == null ? child
                : const SizedBox(width: 120, height: 80, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))))),
          const SizedBox(height: 4), tile,
        ])
      : tile);
  }
}
