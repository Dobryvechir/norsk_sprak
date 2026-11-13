import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/document_store.dart';
import '../services/drive_auth.dart';
import '../services/drive_import.dart';
import '../services/google_drive.dart';
import 'drive_picker_screen.dart';

enum _Status { ready, unsupported, exists, saving, saved, failed }

class _Picked {
  _Picked(PlatformFile this.file, this.folder) : name = file.name, drive = null;
  /// A file on Google Drive, got (and converted when needed) only when saved.
  _Picked.drive(DrivePick this.drive) : file = null, name = drive.plan.name, folder = DocFolder.forFile(drive.plan.name);
  final PlatformFile? file;
  final DrivePick? drive;
  final String name;
  final DocFolder? folder;
  _Status status = _Status.ready;
  String? error;
}

/// Saves files chosen from this device or Google Drive permanently in Documents: pictures (.png, .jpg, .jpeg, .gif)
/// into `document/pictures`, PDFs into `document/pdf` and sheets (.xlsx) into `document/sheets`.
/// Files can be added in several rounds and removed again before saving; a file whose name is
/// already taken is skipped unless "Replace" is on. Drive files are converted to these types (see [planImport]).
class DocumentUploadScreen extends StatefulWidget {
  const DocumentUploadScreen({super.key});
  @override State<DocumentUploadScreen> createState() => _DocumentUploadScreenState();
}

class _DocumentUploadScreenState extends State<DocumentUploadScreen> {
  final store = DocumentStore.instance;
  final picked = <_Picked>[];
  late final _importer = DriveImporter(GoogleDrive());
  bool replace = false, busy = false;
  int done = 0, toSave = 0;

  /// The documents' extensions: Google Drive files are matched and converted to them.
  static final _target = ImportTarget([for (final f in DocFolder.values) ...f.extensions]);

  Future<void> chooseOnDrive() async {
    final chosen = await pickFromDrive(context, _target, multiple: true);
    if (chosen.isEmpty || !mounted) return;
    setState(() {
      for (final d in chosen) {
        final item = _Picked.drive(d);
        picked.removeWhere((p) => p.name == item.name);
        if (item.folder == null || !validDocumentName(item.name)) item.status = _Status.unsupported;
        picked.add(item);
      }
    });
    await checkExisting();
  }

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
        picked.removeWhere((p) => p.name == f.name); // the newest choice of a name wins
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
      final exists = await store.exists(p.folder!, p.name);
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
        final drive = p.drive;
        final bytes = drive != null ? (await _importer.fetch(drive.file, drive.plan)).bytes : p.file!.bytes;
        final path = p.file?.path;
        if (bytes != null) { await store.write(p.folder!, p.name, bytes); }
        else if (path != null && !kIsWeb) { await store.copyFile(p.folder!, p.name, path); }
        else { throw StateError(trNow('docCannotRead')); }
        p.status = _Status.saved; saved++;
      } catch (e) {
        p.status = _Status.failed; p.error = e is StateError ? e.message : e is DriveException ? e.message : '$e';
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
          if (DriveAuth.instance.configured) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: busy ? null : chooseOnDrive, icon: const Icon(Icons.add_to_drive), label: Text(context.tr('driveChooseFrom'))),
          ],
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

  /// The size, or for a Drive file where it comes from (and what it is converted to).
  String _source(BuildContext context, _Picked p) {
    final drive = p.drive;
    if (drive == null) return formatBytes(p.file!.size);
    final size = drive.file.size;
    return drive.plan.method != ImportMethod.download
      ? '${context.tr('driveName')} · ${context.tr('driveConvertedTo', {'format': drive.plan.extension.substring(1).toUpperCase()})}'
      : size == null ? context.tr('driveName') : '${context.tr('driveName')} · ${formatBytes(size)}';
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
      title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text.rich(TextSpan(children: [
        TextSpan(text: '${_source(context, p)}${folder == null ? '' : '  →  ${folder.path}'}\n'),
        WidgetSpan(alignment: PlaceholderAlignment.middle, child: Icon(icon, size: 16, color: color)),
        TextSpan(text: ' $text', style: TextStyle(color: color)),
      ])),
      isThreeLine: true,
      trailing: IconButton(tooltip: context.tr('docRemove'), onPressed: busy ? null : () => setState(() => picked.remove(p)),
        icon: const Icon(Icons.close)),
    );
  }
}
