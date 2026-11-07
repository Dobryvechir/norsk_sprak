import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/document_store.dart';
import 'document_view_screen.dart';

/// The documents of one [folder] on this device: pictures as a grid of thumbnails, PDFs and sheets
/// as a list. Each can be viewed (full screen) or deleted.
class DocumentListScreen extends StatefulWidget {
  final DocFolder folder;
  const DocumentListScreen({super.key, required this.folder});
  @override State<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends State<DocumentListScreen> {
  final store = DocumentStore.instance;
  late Future<List<DocEntry>> future;

  DocFolder get folder => widget.folder;

  @override void initState() { super.initState(); load(); }
  void load() => setState(() { future = store.list(folder); });

  String get titleKey => switch (folder) { DocFolder.pictures => 'docPictures', DocFolder.pdf => 'docPdf', DocFolder.sheets => 'docSheets' };

  Future<void> delete(DocEntry e) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(ctx.tr('mediaDeleteQuestion', {'name': e.name})),
      content: Text(ctx.tr('docDeleteInfo')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('delete'))),
      ]));
    if (ok != true || !mounted) return;
    try { await store.delete(folder, e.name); }
    catch (err) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$err'))); }
    load();
  }

  Future<void> view(List<DocEntry> all, int index) async {
    await Navigator.push(context, MaterialPageRoute(fullscreenDialog: true,
      builder: (_) => DocumentViewScreen(folder: folder, names: [for (final e in all) e.name], index: index)));
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr(titleKey)), actions: [
      IconButton(tooltip: context.tr('refresh'), onPressed: load, icon: const Icon(Icons.refresh))]),
    body: FutureBuilder<List<DocEntry>>(future: future, builder: (ctx, snap) {
      if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
      if (snap.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}', textAlign: TextAlign.center)));
      final files = snap.data!;
      if (files.isEmpty) return Center(child: Text(context.tr('mediaEmpty')));
      if (folder == DocFolder.pictures) {
        return GridView.builder(padding: const EdgeInsets.all(12), itemCount: files.length,
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.82),
          itemBuilder: (_, i) => _PictureTile(entry: files[i], onView: () => view(files, i), onDelete: () => delete(files[i])));
      }
      return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: ListView.builder(
        padding: const EdgeInsets.all(12), itemCount: files.length,
        itemBuilder: (_, i) => Card(child: ListTile(
          leading: Icon(folder.icon, color: Theme.of(context).colorScheme.primary),
          title: Text(files[i].name, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(formatBytes(files[i].size)),
          onTap: () => view(files, i),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(tooltip: context.tr('view'), onPressed: () => view(files, i), icon: const Icon(Icons.visibility)),
            IconButton(tooltip: context.tr('delete'), onPressed: () => delete(files[i]),
              icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error)),
          ]))))));
    }),
  );
}

class _PictureTile extends StatelessWidget {
  final DocEntry entry; final VoidCallback onView, onDelete;
  const _PictureTile({required this.entry, required this.onView, required this.onDelete});

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = DocumentStore.instance;
    final placeholder = ColoredBox(color: theme.colorScheme.primaryContainer,
      child: Icon(Icons.broken_image_outlined, color: theme.colorScheme.onPrimaryContainer));
    final Widget image = kIsWeb
      ? FutureBuilder<Uint8List>(future: store.read(DocFolder.pictures, entry.name), builder: (_, snap) => snap.hasError ? placeholder
          : !snap.hasData ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          : Image.memory(snap.data!, fit: BoxFit.cover, cacheWidth: 400, errorBuilder: (_, __, ___) => placeholder))
      : FutureBuilder<String?>(future: store.filePath(DocFolder.pictures, entry.name), builder: (_, snap) => !snap.hasData ? const SizedBox.shrink()
          : Image.file(File(snap.data!), fit: BoxFit.cover, cacheWidth: 400, errorBuilder: (_, __, ___) => placeholder));
    return Card(clipBehavior: Clip.antiAlias, margin: EdgeInsets.zero, child: InkWell(onTap: onView, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: image),
      Padding(padding: const EdgeInsets.only(left: 8), child: Row(children: [
        Expanded(child: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
        IconButton(tooltip: context.tr('delete'), visualDensity: VisualDensity.compact, onPressed: onDelete,
          icon: Icon(Icons.delete_outline, color: theme.colorScheme.error)),
      ])),
    ])));
  }
}
