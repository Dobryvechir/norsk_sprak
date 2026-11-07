import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/document_store.dart';
import '../services/media_store.dart';

/// Asks for a name for a picture just taken with the camera, then saves it permanently on this
/// device in `document/pictures` (adding `.jpg` or `.png` unless the name has a picture extension).
/// The temporary copy is deleted either way. Returns true when saved.
Future<bool> showDocumentSaveDialog(BuildContext context, LocalMedia media) async {
  final saved = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => _DocumentSaveDialog(media: media));
  await media.delete();
  return saved ?? false;
}

class _DocumentSaveDialog extends StatefulWidget {
  final LocalMedia media;
  const _DocumentSaveDialog({required this.media});
  @override State<_DocumentSaveDialog> createState() => _DocumentSaveDialogState();
}

class _DocumentSaveDialogState extends State<_DocumentSaveDialog> {
  final name = TextEditingController();
  late final Future<Uint8List> preview = widget.media.readBytes();
  bool saving = false;
  String? error;

  @override void dispose() { name.dispose(); super.dispose(); }

  String get extension => widget.media.mimeType == 'image/png' ? '.png' : widget.media.mimeType == 'image/gif' ? '.gif' : '.jpg';

  Future<void> save() async {
    var text = name.text.trim();
    if (text.isEmpty) { setState(() => error = context.tr('mediaNameRequired')); return; }
    if (!validDocumentName(text)) { setState(() => error = context.tr('mediaNameInvalid')); return; }
    if (!DocFolder.pictures.accepts(text)) text = '$text$extension';
    setState(() { saving = true; error = null; });
    final store = DocumentStore.instance;
    try {
      if (await store.exists(DocFolder.pictures, text)) throw StateError(trNow('mediaNameExists', {'name': text}));
      final path = widget.media.path;
      path != null && !kIsWeb ? await store.moveFile(DocFolder.pictures, text, path)
        : await store.write(DocFolder.pictures, text, await widget.media.readBytes());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { saving = false; error = e is StateError ? e.message : '$e'; });
    }
  }

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = widget.media.path;
    return PopScope(canPop: false, child: AlertDialog(
      title: Text(context.tr('docSaveTitle')),
      content: SizedBox(width: 360, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: 160, child: Center(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: path != null && !kIsWeb
          ? Image.file(File(path), fit: BoxFit.contain, cacheWidth: 480)
          : FutureBuilder<Uint8List>(future: preview, builder: (_, snap) => snap.hasData
              ? Image.memory(snap.data!, fit: BoxFit.contain, cacheWidth: 480) : const CircularProgressIndicator())))),
        const SizedBox(height: 16),
        TextField(controller: name, autofocus: true, enabled: !saving, textInputAction: TextInputAction.done,
          onSubmitted: (_) => save(),
          decoration: InputDecoration(labelText: context.tr('mediaName'), suffixText: extension, border: const OutlineInputBorder())),
        if (saving) ...[const SizedBox(height: 16), const LinearProgressIndicator()],
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: theme.colorScheme.error))),
      ]))),
      actions: [
        TextButton(onPressed: saving ? null : () => Navigator.pop(context, false), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: saving ? null : save, child: Text(context.tr('save'))),
      ],
    ));
  }
}
