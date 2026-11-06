import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/google_drive.dart';
import '../services/media_store.dart';

/// Asks for a name for newly captured [media], then saves it to Google Drive: the media into
/// `/media/<kind.folder>/<name>`, then its icon into `/media/<kind.iconFolder>/<name>` (creating
/// folders as needed). On an error the dialog stays open with the error shown. When both are saved,
/// or on Cancel, the local copy is deleted. Returns true when saved.
Future<bool> showMediaSaveDialog(BuildContext context, GoogleDrive drive, LocalMedia media, {Duration? duration}) async {
  final saved = await showDialog<bool>(context: context, barrierDismissible: false,
    builder: (_) => _MediaSaveDialog(drive: drive, media: media, duration: duration));
  await media.delete(); // in case the dialog was closed some other way
  return saved ?? false;
}

class _MediaSaveDialog extends StatefulWidget {
  final GoogleDrive drive; final LocalMedia media; final Duration? duration;
  const _MediaSaveDialog({required this.drive, required this.media, this.duration});
  @override State<_MediaSaveDialog> createState() => _MediaSaveDialogState();
}

class _MediaSaveDialogState extends State<_MediaSaveDialog> {
  final name = TextEditingController();
  late final Future<(Uint8List, String)> icon = makeIcon(widget.media, duration: widget.duration);
  bool saving = false;
  double? progress;
  String? error;
  /// The media already uploaded by an earlier Save whose icon then failed: (name, file id).
  (String, String)? uploaded;

  @override void dispose() { name.dispose(); super.dispose(); }

  String? validate(String text) {
    if (text.isEmpty) return context.tr('mediaNameRequired');
    if (text.contains('/') || text.contains(r'\')) return context.tr('mediaNameInvalid');
    return null;
  }

  Future<void> save() async {
    final text = name.text.trim();
    final invalid = validate(text);
    if (invalid != null) { setState(() => error = invalid); return; }
    final kind = widget.media.kind, drive = widget.drive;
    setState(() { saving = true; error = null; progress = null; });
    try {
      // Renamed after a half-finished save: start over under the new name.
      final previous = uploaded;
      if (previous != null && previous.$1 != text) { await drive.delete(previous.$2); uploaded = null; }
      if (uploaded == null) {
        if (await drive.mediaExists(kind, text)) throw DriveException(trNow('mediaNameExists', {'name': text}));
        final folderId = (await drive.mediaFolder(kind, create: true))!;
        final id = await drive.uploadMedia(folderId, text, widget.media,
          onProgress: (sent, total) { if (mounted && total > 0) setState(() => progress = sent / total); });
        uploaded = (text, id);
      }
      if (mounted) setState(() => progress = null);
      final (iconBytes, iconType) = await icon;
      await drive.uploadBytes((await drive.iconFolder(kind, create: true))!, text, iconType, iconBytes);
      await widget.media.delete();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { saving = false; progress = null; error = e is DriveException ? e.message : '$e'; });
    }
  }

  /// Removes the local copy, and what a half-finished save left on Drive.
  Future<void> cancel() async {
    setState(() => saving = true);
    final previous = uploaded;
    if (previous != null) { try { await widget.drive.delete(previous.$2); } catch (_) {} }
    await widget.media.delete();
    if (mounted) Navigator.pop(context, false);
  }

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(canPop: false, child: AlertDialog(
      title: Text(context.tr('mediaSaveTitle')),
      content: SizedBox(width: 360, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FutureBuilder<(Uint8List, String)>(future: icon, builder: (_, snap) => SizedBox(height: 120, child: Center(child: snap.hasData
          ? ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(snap.data!.$1, fit: BoxFit.contain))
          : const CircularProgressIndicator()))),
        const SizedBox(height: 16),
        TextField(controller: name, autofocus: true, enabled: !saving, textInputAction: TextInputAction.done,
          onSubmitted: (_) => save(),
          decoration: InputDecoration(labelText: context.tr('mediaName'), border: const OutlineInputBorder())),
        if (saving) ...[const SizedBox(height: 16), LinearProgressIndicator(value: progress)],
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12),
          child: Text(error!, style: TextStyle(color: theme.colorScheme.error))),
      ]))),
      actions: [
        TextButton(onPressed: saving ? null : cancel, child: Text(context.tr('cancel'))),
        FilledButton(onPressed: saving ? null : save, child: Text(context.tr('save'))),
      ],
    ));
  }
}
