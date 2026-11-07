import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/google_drive.dart';
import '../services/media_store.dart';
import 'media_view_screen.dart';

/// The saved media of one [kind], 10 per page: the names and icons come from
/// `/media/<kind.iconFolder>` on Google Drive. Each item can be viewed or deleted; with [picking] a tap
/// instead closes the screen with the media file itself (a [DriveFile]), for Chat.
class MediaListScreen extends StatefulWidget {
  final GoogleDrive drive; final MediaKind kind; final bool picking;
  const MediaListScreen({super.key, required this.drive, required this.kind, this.picking = false});
  @override State<MediaListScreen> createState() => _MediaListScreenState();
}

class _MediaListScreenState extends State<MediaListScreen> {
  static const pageSize = 10;
  /// Drive's token for each page reached so far (null for the first).
  final pageTokens = <String?>[null];
  int page = 0;
  late Future<DrivePage> future;
  /// Icons downloaded so far, by Drive file id (kept in memory only).
  final icons = <String, Future<Uint8List>>{};

  MediaKind get kind => widget.kind;

  @override void initState() { super.initState(); load(); }

  void load() => setState(() { future = _fetch(pageTokens[page]); });

  Future<DrivePage> _fetch(String? token) async {
    final folderId = await widget.drive.iconFolder(kind);
    if (folderId == null) return const DrivePage([], null); // nothing saved yet
    final result = await widget.drive.list(folderId, pageToken: token, pageSize: pageSize);
    if (result.nextPageToken != null) {
      if (pageTokens.length > page + 1) { pageTokens[page + 1] = result.nextPageToken; }
      else { pageTokens.add(result.nextPageToken); }
    } else {
      pageTokens.removeRange(page + 1, pageTokens.length);
    }
    return result;
  }

  void goTo(int p) { page = p; load(); }

  /// The icon's bytes; empty when it can't be downloaded (a placeholder is shown; Refresh tries again).
  Future<Uint8List> icon(DriveFile f) => icons[f.id] ??= widget.drive.downloadBytes(f.id).catchError((Object _) => Uint8List(0));

  Future<void> delete(DriveFile f) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(ctx.tr('mediaDeleteQuestion', {'name': f.name})),
      content: Text(ctx.tr('mediaDeleteInfo')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('delete'))),
      ]));
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.drive.deleteMedia(kind, f.name);
      await MediaTemp.forgetViewed(kind, f.name);
      icons.remove(f.id);
      // The page may now be empty: then show the one before.
      final rest = await _fetch(pageTokens[page]);
      if (rest.files.isEmpty && page > 0) { goTo(page - 1); } else { setState(() => future = Future.value(rest)); }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e is DriveException ? e.message : '$e')));
    }
  }

  void view(DriveFile f) => Navigator.push(context, MaterialPageRoute(fullscreenDialog: true,
    builder: (_) => MediaViewScreen(drive: widget.drive, kind: kind, name: f.name)));

  Future<void> pick(DriveFile icon) async {
    final messenger = ScaffoldMessenger.of(context), navigator = Navigator.of(context);
    try {
      final file = await widget.drive.findMedia(kind, icon.name);
      if (file == null) throw DriveException(trNow('mediaNotFound', {'name': icon.name}));
      navigator.pop(file);
    } catch (e) { messenger.showSnackBar(SnackBar(content: Text(e is DriveException ? e.message : '$e'))); }
  }

  String get titleKey => switch (kind) { MediaKind.picture => 'mediaPictures', MediaKind.video => 'mediaVideos', MediaKind.audio => 'mediaAudio' };

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr(titleKey)), actions: [
      IconButton(tooltip: context.tr('refresh'), onPressed: () { icons.clear(); load(); }, icon: const Icon(Icons.refresh))]),
    body: FutureBuilder<DrivePage>(future: future, builder: (ctx, snap) {
      if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
      if (snap.hasError) {
        final e = snap.error!;
        return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(e is DriveException ? e.message : '$e', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: load, icon: const Icon(Icons.refresh), label: Text(context.tr('refresh'))),
        ])));
      }
      final files = snap.data!.files;
      final hasNext = page + 1 < pageTokens.length;
      return Column(children: [
        Expanded(child: files.isEmpty ? Center(child: Text(context.tr('mediaEmpty'))) : Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640), child: ListView.builder(padding: const EdgeInsets.all(12), itemCount: files.length,
            itemBuilder: (_, i) => _MediaTile(file: files[i], kind: kind, icon: icon(files[i]),
              picking: widget.picking, onView: () => widget.picking ? pick(files[i]) : view(files[i]),
              onDelete: () => delete(files[i])))))),
        if (page > 0 || hasNext) SafeArea(top: false, child: Padding(padding: const EdgeInsets.only(bottom: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(tooltip: context.tr('previousPage'), onPressed: page > 0 ? () => goTo(page - 1) : null, icon: const Icon(Icons.chevron_left)),
            Text(context.tr('pageNumber', {'page': page + 1})),
            IconButton(tooltip: context.tr('nextPage'), onPressed: hasNext ? () => goTo(page + 1) : null, icon: const Icon(Icons.chevron_right)),
          ]))),
      ]);
    }),
  );
}

class _MediaTile extends StatelessWidget {
  final DriveFile file; final MediaKind kind; final Future<Uint8List> icon; final bool picking;
  final VoidCallback onView, onDelete;
  const _MediaTile({required this.file, required this.kind, required this.icon, required this.onView, required this.onDelete, this.picking = false});
  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = ColoredBox(color: theme.colorScheme.primaryContainer, child: Icon(kind.icon, color: theme.colorScheme.onPrimaryContainer));
    return Card(clipBehavior: Clip.antiAlias, child: InkWell(onTap: onView, child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      ClipRRect(borderRadius: BorderRadius.circular(6), child: SizedBox(width: 72, height: 72, child: FutureBuilder<Uint8List>(future: icon,
        builder: (_, snap) => !snap.hasData ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          : snap.data!.isEmpty ? placeholder
          : Image.memory(snap.data!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder)))),
      const SizedBox(width: 12),
      Expanded(child: Text(file.name, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis)),
      if (picking) IconButton(tooltip: context.tr('chatSend'), onPressed: onView, icon: const Icon(Icons.send))
      else ...[
        IconButton(tooltip: context.tr(kind == MediaKind.audio ? 'listen' : 'view'), onPressed: onView,
          icon: Icon(kind == MediaKind.picture ? Icons.visibility : Icons.play_circle_outline)),
        IconButton(tooltip: context.tr('delete'), onPressed: onDelete, icon: Icon(Icons.delete_outline, color: theme.colorScheme.error)),
      ],
    ]))));
  }
}
