import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/chat.dart';
import '../services/api.dart';
import '../services/chat_api.dart';
import '../services/media_store.dart';
import 'camera_capture_screen.dart';
import 'chat_widgets.dart';

/// Longest side of the chat photo, in pixels (it is stored on our server, so it stays small).
const chatPhotoSize = 96;

/// The name and small photo others see in Chat. A photo is required before taking part.
/// Pops with true when saved.
class ChatProfileScreen extends StatefulWidget {
  final ChatApi chat; final ChatStatus status;
  const ChatProfileScreen({super.key, required this.chat, required this.status});
  @override State<ChatProfileScreen> createState() => _ChatProfileScreenState();
}

class _ChatProfileScreenState extends State<ChatProfileScreen> {
  late final name = TextEditingController(text: widget.status.displayName);
  /// The new photo, as a small PNG; null keeps the current one.
  Uint8List? photo;
  bool saving = false;
  String? error;

  @override void dispose() { name.dispose(); super.dispose(); }

  Future<void> usePicture(Uint8List bytes) async {
    try {
      final small = await shrinkImage(bytes, chatPhotoSize);
      if (mounted) setState(() { photo = small; error = null; });
    } catch (_) { if (mounted) setState(() => error = context.tr('docCannotRead')); }
  }

  Future<void> chooseFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final bytes = result?.files.single.bytes;
    if (bytes != null) await usePicture(bytes);
  }

  Future<void> takePicture() => Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => CameraCaptureScreen(
    kind: MediaKind.picture, onCaptured: (_, media, __) async { await usePicture(await media.readBytes()); await media.delete(); })));

  Future<void> save() async {
    final text = name.text.trim();
    if (text.isEmpty) { setState(() => error = context.tr('mediaNameRequired')); return; }
    if (photo == null && !widget.status.hasPhoto) { setState(() => error = context.tr('chatPhotoRequired')); return; }
    setState(() { saving = true; error = null; });
    try {
      await widget.chat.saveProfile(text, photo);
      if (mounted) Navigator.pop(context, true);
    } catch (e) { if (mounted) setState(() { saving = false; error = readableError(e); }); }
  }

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.status;
    return Scaffold(appBar: AppBar(title: Text(context.tr('chatProfile'))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: ListView(padding: const EdgeInsets.all(16), children: [
        Text(context.tr('chatProfileInfo')),
        const SizedBox(height: 24),
        Center(child: photo != null ? CircleAvatar(radius: 56, backgroundImage: MemoryImage(photo!))
          : ChatAvatar(chat: widget.chat, person: current, radius: 56)),
        const SizedBox(height: 12),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: saving ? null : takePicture, icon: const Icon(Icons.photo_camera), label: Text(context.tr('chatTakePhoto'))),
          OutlinedButton.icon(onPressed: saving ? null : chooseFile, icon: const Icon(Icons.image), label: Text(context.tr('chatChoosePhoto'))),
        ]),
        const SizedBox(height: 24),
        TextField(controller: name, enabled: !saving, maxLength: 60,
          decoration: InputDecoration(labelText: context.tr('chatDisplayName'), border: const OutlineInputBorder())),
        if (error != null) Padding(padding: const EdgeInsets.only(bottom: 12),
          child: Text(error!, style: TextStyle(color: theme.colorScheme.error))),
        FilledButton.icon(onPressed: saving ? null : save, icon: saving
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
          label: Text(context.tr('save'))),
      ]))));
  }
}
