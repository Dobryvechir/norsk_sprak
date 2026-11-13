import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/document_store.dart' show formatBytes;
import '../services/drive_import.dart';
import '../services/google_drive.dart';

/// A file chosen on Google Drive, with how it becomes a file of the expected type.
class DrivePick {
  const DrivePick(this.file, this.plan);
  final DriveFile file;
  final ImportPlan plan;
}

/// Opens [DrivePickerScreen]; returns the chosen files (empty when nothing was chosen).
Future<List<DrivePick>> pickFromDrive(BuildContext context, ImportTarget target, {bool multiple = false, GoogleDrive? drive}) async =>
  await Navigator.push<List<DrivePick>>(context, MaterialPageRoute(fullscreenDialog: true,
    builder: (_) => DrivePickerScreen(drive: drive ?? GoogleDrive(), target: target, multiple: multiple))) ?? const [];

/// Browses the user's Google Drive (My Drive, Shared with me, or a search) to choose files for [target].
/// Files that can't be used there are shown dimmed; those that will be converted say into what.
class DrivePickerScreen extends StatefulWidget {
  const DrivePickerScreen({super.key, required this.drive, required this.target, this.multiple = false});
  final GoogleDrive drive;
  final ImportTarget target;
  final bool multiple;
  @override State<DrivePickerScreen> createState() => _DrivePickerScreenState();
}

class _DrivePickerScreenState extends State<DrivePickerScreen> {
  /// The folders opened, from the top ([DriveFile.id] 'root' for My Drive, '' for Shared with me).
  final path = <DriveFile>[const DriveFile('root', '', GoogleDrive.folderType)];
  final items = <DriveFile>[];
  final chosen = <String, DrivePick>{};
  final search = TextEditingController();
  Timer? _debounce;
  String? nextPage, error;
  bool loading = false;
  /// Bumped on each new listing, so that late answers for an older one are dropped.
  int _generation = 0;

  bool get sharedWithMe => path.first.id == '';
  String get query => search.text.trim();

  @override void initState() { super.initState(); reload(); }
  @override void dispose() { _debounce?.cancel(); search.dispose(); super.dispose(); }

  Future<void> reload() async { items.clear(); nextPage = null; await loadMore(fresh: true); }

  Future<void> loadMore({bool fresh = false}) async {
    final generation = fresh ? ++_generation : _generation;
    setState(() { loading = true; error = null; });
    try {
      final top = path.length == 1;
      final page = await widget.drive.browse(folderId: path.last.id, search: query.isEmpty ? null : query,
        sharedWithMe: sharedWithMe && top, pageToken: fresh ? null : nextPage);
      if (generation != _generation || !mounted) return;
      setState(() { items.addAll(page.files); nextPage = page.nextPageToken; });
    } catch (e) {
      if (generation == _generation && mounted) setState(() => error = e is DriveException ? e.message : '$e');
    } finally {
      if (generation == _generation && mounted) setState(() => loading = false);
    }
  }

  void open(DriveFile folder) { search.clear(); setState(() => path.add(folder)); reload(); }
  void goUp(int index) { search.clear(); setState(() => path.removeRange(index + 1, path.length)); reload(); }
  void switchRoot(bool shared) {
    if (shared == sharedWithMe && path.length == 1) return;
    search.clear();
    setState(() { path..clear()..add(DriveFile(shared ? '' : 'root', '', GoogleDrive.folderType)); });
    reload();
  }
  void onSearch(String _) { _debounce?.cancel(); _debounce = Timer(const Duration(milliseconds: 400), reload); }

  void tap(DriveFile f, ImportPlan? plan) {
    if (f.isFolder) { open(f); return; }
    if (plan == null) return;
    if (!widget.multiple) { Navigator.pop(context, [DrivePick(f, plan)]); return; }
    setState(() { if (chosen.remove(f.id) == null) chosen[f.id] = DrivePick(f, plan); });
  }

  static IconData iconFor(DriveFile f) {
    final t = f.mimeType;
    if (f.isFolder) return Icons.folder;
    if (t == googleDocument) return Icons.description;
    if (t == googleSpreadsheet || t.contains('spreadsheet') || t.contains('excel') || t.contains('csv')) return Icons.table_chart;
    if (t == googlePresentation || t.contains('presentation') || t.contains('powerpoint')) return Icons.slideshow;
    if (t == googleDrawing || t.startsWith('image/')) return Icons.image;
    if (t.contains('pdf')) return Icons.picture_as_pdf;
    if (t.startsWith('audio/')) return Icons.audio_file;
    if (t.startsWith('video/')) return Icons.video_file;
    return Icons.insert_drive_file_outlined;
  }

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('driveChooseTitle')), actions: [
        IconButton(tooltip: context.tr('refresh'), onPressed: loading ? null : reload, icon: const Icon(Icons.refresh))]),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: TextField(controller: search, onChanged: onSearch,
          decoration: InputDecoration(isDense: true, prefixIcon: const Icon(Icons.search), hintText: context.tr('driveSearch'),
            border: const OutlineInputBorder(),
            suffixIcon: search.text.isEmpty ? null : IconButton(onPressed: () { search.clear(); reload(); }, icon: const Icon(Icons.clear))))),
        if (query.isEmpty) SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            ChoiceChip(label: Text(context.tr('driveMyDrive')), selected: !sharedWithMe, onSelected: (_) => switchRoot(false)),
            const SizedBox(width: 8),
            ChoiceChip(label: Text(context.tr('driveSharedWithMe')), selected: sharedWithMe, onSelected: (_) => switchRoot(true)),
            for (var i = 1; i < path.length; i++) ...[
              const Icon(Icons.chevron_right, size: 18),
              TextButton(onPressed: i == path.length - 1 ? null : () => goUp(i), child: Text(path[i].name)),
            ],
          ])),
        const Divider(height: 1),
        Expanded(child: _list(context, theme)),
        if (widget.multiple) SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
          if (chosen.isNotEmpty) TextButton(onPressed: () => setState(chosen.clear), child: Text(context.tr('docClearList'))),
          const Spacer(),
          FilledButton.icon(onPressed: chosen.isEmpty ? null : () => Navigator.pop(context, chosen.values.toList()),
            icon: const Icon(Icons.check), label: Text(context.tr('driveChooseCount', {'count': chosen.length}))),
        ]))),
      ]))),
    );
  }

  Widget _list(BuildContext context, ThemeData theme) {
    if (error != null && items.isEmpty) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: reload, icon: const Icon(Icons.refresh), label: Text(context.tr('refresh'))),
      ])));
    }
    if (items.isEmpty) {
      return Center(child: loading ? const CircularProgressIndicator() : Text(context.tr('driveEmpty')));
    }
    final more = nextPage != null || loading;
    return ListView.builder(itemCount: items.length + (more ? 1 : 0), itemBuilder: (_, i) {
      if (i == items.length) {
        return Padding(padding: const EdgeInsets.all(12), child: Center(child: loading ? const CircularProgressIndicator()
          : OutlinedButton(onPressed: () => loadMore(), child: Text(context.tr('driveLoadMore')))));
      }
      final f = items[i];
      final plan = f.isFolder ? null : planImport(f, widget.target);
      final usable = f.isFolder || plan != null;
      final String? note = f.isFolder ? null
        : plan == null ? context.tr('driveNotUsableHere')
        : plan.method == ImportMethod.download ? (f.size == null ? null : formatBytes(f.size!))
        : context.tr('driveConvertedTo', {'format': plan.extension.substring(1).toUpperCase()});
      final selected = chosen.containsKey(f.id);
      return ListTile(
        enabled: usable,
        leading: Icon(iconFor(f), color: usable ? theme.colorScheme.primary : null),
        title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: note == null ? null : Text(note),
        trailing: f.isFolder ? const Icon(Icons.chevron_right)
          : widget.multiple && usable ? Checkbox(value: selected, onChanged: (_) => tap(f, plan)) : null,
        selected: selected,
        onTap: () => tap(f, plan),
      );
    });
  }
}
