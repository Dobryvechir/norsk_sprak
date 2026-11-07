import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/document_store.dart';

enum _Status { ready, unsupported, exists, saving, saved, failed }

class _Picked {
  _Picked(this.file, this.folder);
  final PlatformFile file;
  final DocFolder? folder;
  _Status status = _Status.ready;
  String? error;
}

/// Saves files chosen from this device permanently in Documents: pictures (.png, .jpg, .jpeg, .gif)
/// into `document/pictures`, PDFs into `document/pdf` and sheets (.xlsx) into `document/sheets`.
/// Files can be added in several rounds and removed again before saving; a file whose name is
/// already taken is skipped unless "Replace" is on.
class DocumentUploadScreen extends StatefulWidget {
  const DocumentUploadScreen({super.key});
  @override State<DocumentUploadScreen> createState() => _DocumentUploadScreenState();
}

class _DocumentUploadScreenState extends State<DocumentUploadScreen> {
  final store = DocumentStore.instance;
  final picked = <_Picked>[];
  bool replace = false, busy = false;
  int done = 0, toSave = 0;

  Future<void> pick() async {
    // On Android, FileType.custom turns extensions into MIME types that often don't match what the
    // file providers report, so files appear disabled: there any file can be picked and checked here.
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(allowMultiple: true, withData: kIsWeb,
        type: android ? FileType.any : FileType.custom, allowedExtensions: android ? null : DocFolder.allExtensions);
    } catch (e) { showMessage('$e'); return; }
    if (result == null) return;
    setState(() {
      for (final f in result!.files) {
        picked.removeWhere((p) => p.file.name == f.name); // the newest choice of a name wins
        final item = _Picked(f, DocFolder.forFile(f.name));
        if (item.folder == null || !validDocumentName(f.name)) item.status = _Status.unsupported;
        picked.add(item);
      }
    });
    await checkExisting();
  }

  /// Marks the files whose name is already taken in their folder.
  Future<void> checkExisting() async {
    for (final p in picked) {
      if (p.folder == null || p.status == _Status.saved || p.status == _Status.unsupported) continue;
      final exists = await store.exists(p.folder!, p.file.name);
      p.status = exists ? _Status.exists : _Status.ready;
    }
    if (mounted) setState(() {});
  }

  bool willSave(_Picked p) => p.status == _Status.ready || p.status == _Status.failed || (replace && p.status == _Status.exists);

  Future<void> saveAll() async {
    final items = picked.where(willSave).toList();
    if (items.isEmpty) return;
    setState(() { busy = true; done = 0; toSave = items.length; });
    var saved = 0;
    for (final p in items) {
      setState(() { p.status = _Status.saving; p.error = null; });
      try {
        final bytes = p.file.bytes, path = p.file.path;
        if (bytes != null) { await store.write(p.folder!, p.file.name, bytes); }
        else if (path != null && !kIsWeb) { await store.copyFile(p.folder!, p.file.name, path); }
        else { throw StateError(trNow('docCannotRead')); }
        p.status = _Status.saved; saved++;
      } catch (e) {
        p.status = _Status.failed; p.error = e is StateError ? e.message : '$e';
      }
      if (mounted) setState(() => done++);
    }
    if (!mounted) return;
    setState(() => busy = false);
    showMessage(context.tr('docSavedCount', {'count': saved}));
  }

  void showMessage(String text) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text))); }

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = picked.where(willSave).length;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('docUpload'))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(context.tr('docUploadHint'), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: busy ? null : pick, icon: const Icon(Icons.folder_open), label: Text(context.tr('docChooseFiles'))),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: replace, title: Text(context.tr('docReplace')),
            onChanged: busy ? null : (v) => setState(() => replace = v)),
        ])),
        const Divider(height: 1),
        Expanded(child: picked.isEmpty ? Center(child: Text(context.tr('docNothingChosen'), style: theme.textTheme.bodyMedium))
          : ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [for (final p in picked) _tile(context, p)])),
        if (picked.isNotEmpty) SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
          if (busy) ...[LinearProgressIndicator(value: toSave == 0 ? null : done / toSave), const SizedBox(height: 12)],
          Row(children: [
            TextButton(onPressed: busy ? null : () => setState(picked.clear), child: Text(context.tr('docClearList'))),
            const Spacer(),
            FilledButton.icon(onPressed: busy || count == 0 ? null : saveAll, icon: const Icon(Icons.save),
              label: Text('${context.tr('docSaveAll')} ($count)')),
          ]),
        ]))),
      ]))),
    );
  }

  Widget _tile(BuildContext context, _Picked p) {
    final theme = Theme.of(context);
    final (IconData icon, Color? color, String text) = switch (p.status) {
      _Status.ready => (Icons.schedule, null, context.tr('docReady')),
      _Status.unsupported => (Icons.block, theme.colorScheme.error,
        context.tr('unsupportedFileType', {'types': DocFolder.allExtensions.join(', ')})),
      _Status.exists => (replace ? Icons.sync_problem : Icons.info_outline, theme.colorScheme.tertiary,
        context.tr(replace ? 'docWillReplace' : 'docExists')),
      _Status.saving => (Icons.hourglass_top, null, context.tr('docSaving')),
      _Status.saved => (Icons.check_circle, Colors.green, context.tr('docSaved')),
      _Status.failed => (Icons.error_outline, theme.colorScheme.error, p.error ?? ''),
    };
    final folder = p.folder;
    return ListTile(
      leading: Icon(folder?.icon ?? Icons.insert_drive_file_outlined),
      title: Text(p.file.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text.rich(TextSpan(children: [
        TextSpan(text: '${formatBytes(p.file.size)}${folder == null ? '' : '  →  ${folder.path}'}\n'),
        WidgetSpan(alignment: PlaceholderAlignment.middle, child: Icon(icon, size: 16, color: color)),
        TextSpan(text: ' $text', style: TextStyle(color: color)),
      ])),
      isThreeLine: true,
      trailing: IconButton(tooltip: context.tr('docRemove'), onPressed: busy ? null : () => setState(() => picked.remove(p)),
        icon: const Icon(Icons.close)),
    );
  }
}
