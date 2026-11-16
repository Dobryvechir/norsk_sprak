import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/offline_chapters.dart';
import '../services/settings.dart';
import 'books_screen.dart';
import 'chapter_player_screen.dart';
import 'notifications_admin_screen.dart' show formatDateTime;
import 'recording_media_screen.dart';

/// A group's recordings, in three parts:
/// - saved on this device (made here, or downloaded): remove, update from the server (when it is also
///   shared there) and play, as saved book chapters are played. Works without a connection;
/// - being processed: the user's own recordings still queued for AI (or failed), with retry and remove;
/// - shared in the group and not saved here: download, and remove from the server for its author,
///   group admins and system admins.
/// A recording both shared and saved here is shown only among the saved ones.
class LibraryScreen extends StatefulWidget {
  final Api api; final StudyGroup group;
  const LibraryScreen({super.key, required this.api, required this.group});
  @override State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final store = OfflineChapters(widget.api, recordings: true);
  List<Recording>? local, server;
  Object? localError, serverError;
  /// Progress (0–1) of recordings being downloaded or updated, by id.
  final downloading = <String, double>{};

  @override void initState() { super.initState(); refresh(); }

  Future<void> refresh() => Future.wait([loadLocal(), loadServer()]);

  Future<void> loadLocal() async {
    try {
      final saved = await store.all(AppSettings.instance.uiLanguage);
      final mine = [for (final s in saved) if (s.chapter.groupId == widget.group.id) s.chapter];
      if (mounted) setState(() { local = mine; localError = null; });
    } catch (e) { if (mounted) setState(() { local = const []; localError = e; }); }
  }

  Future<void> loadServer() async {
    try {
      final items = await widget.api.recordings(widget.group.id);
      if (mounted) setState(() { server = items; serverError = null; });
    } catch (e) { if (mounted) setState(() { server = null; serverError = e; }); }
  }

  void showError(Object e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }

  Future<void> create() async {
    final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => RecordingMediaScreen(api: widget.api, group: widget.group)));
    if (changed == true) await refresh();
  }

  bool canManage(Recording r) => r.info.uploaderId == widget.api.user?.id || widget.group.isAdmin || widget.api.user?.systemAdmin == true;

  Future<bool> confirm(String title, String question) async => await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
    title: Text(context.tr(title)), content: Text(context.tr(question)), actions: [
      TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.tr('cancel'))),
      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.tr('delete')))])) == true;

  /// Downloads (or updates) the shared recording [r] into this device.
  Future<void> download(Recording r) async {
    setState(() => downloading[r.id] = 0);
    try {
      await store.download(r.id, (v) { if (mounted) setState(() => downloading[r.id] = v); });
      await loadLocal();
    } catch (e) { showError(e); }
    finally { if (mounted) setState(() => downloading.remove(r.id)); }
  }

  Future<void> removeLocal(Recording r) async {
    if (!await confirm('removeLocal', 'removeLocalQuestion')) return;
    try { await store.remove(r.id); await loadLocal(); } catch (e) { showError(e); }
  }

  Future<void> removeFromServer(Recording r) async {
    if (!await confirm('removeFromServer', 'removeFromServerQuestion')) return;
    try { await widget.api.deleteRecording(r.id); await loadServer(); } catch (e) { showError(e); }
  }

  Future<void> retry(Recording r) async {
    try {
      for (final e in r.audio.entries) { if (e.value.status == 'failed') await widget.api.transcribe(r.id, e.key); }
      await loadServer();
    } catch (e) { showError(e); }
  }

  void play(Recording r) => Navigator.push(context, MaterialPageRoute(builder: (_) => ChapterPlayerScreen(api: widget.api, chapter: r, store: store)));

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saved = [...?local]..sort((a, b) => naturalCompare(a.name, b.name));
    final savedIds = {for (final r in saved) r.id};
    final all = server ?? const <Recording>[];
    final serverIds = {for (final r in all) if (r.isReady) r.id};
    final processing = [for (final r in all) if (!r.isReady) r]..sort((a, b) => naturalCompare(a.name, b.name));
    final shared = [for (final r in all) if (r.isReady && !savedIds.contains(r.id)) r]..sort((a, b) => naturalCompare(a.name, b.name));
    Widget heading(String key, IconData icon) => Padding(padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(children: [Icon(icon, size: 20, color: theme.colorScheme.primary), const SizedBox(width: 8),
        Text(context.tr(key), style: theme.textTheme.titleMedium)]));
    Widget note(String text, {bool error = false}) => Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Text(text, style: error ? TextStyle(color: theme.colorScheme.error) : theme.textTheme.bodyMedium));

    return Scaffold(
      appBar: AppBar(title: Text(widget.group.name), actions: [
        IconButton(tooltip: context.tr('refresh'), onPressed: refresh, icon: const Icon(Icons.refresh))]),
      floatingActionButton: widget.api.offline ? null
        : FloatingActionButton.extended(onPressed: create, icon: const Icon(Icons.add), label: Text(context.tr('newRecording'))),
      body: local == null && server == null && serverError == null ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(onRefresh: refresh, child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 88), children: [
          heading('recordingsLocal', Icons.phone_android),
          if (local == null) const LinearProgressIndicator()
          else if (localError != null) note(readableError(localError!), error: true)
          else if (saved.isEmpty) note(context.tr('noLocalRecordings')),
          for (final r in saved) _RecordingCard(recording: r, badge: serverIds.contains(r.id) ? 'alsoShared' : 'onlyOnDevice', actions: [
            IconButton(tooltip: context.tr('removeLocal'), onPressed: () => removeLocal(r), icon: const Icon(Icons.delete_outline)),
            if (serverIds.contains(r.id)) _progressOr(r, OutlinedButton.icon(onPressed: () => download(r),
              icon: const Icon(Icons.sync), label: Text(context.tr('updateFromServer')))),
            FilledButton.icon(onPressed: r.audio.values.any((a) => a.startMs.isNotEmpty) ? () => play(r) : null,
              icon: const Icon(Icons.play_arrow), label: Text(context.tr('play'))),
          ]),

          if (processing.isNotEmpty) ...[
            heading('recordingsProcessing', Icons.hourglass_top),
            for (final r in processing) _RecordingCard(recording: r, status: [
              for (final e in r.audio.entries) '${e.key.toUpperCase()}: ${context.trStatus(e.value.status)}'
                '${e.value.error == null ? '' : ' – ${e.value.error}'}'].join('\n'), actions: [
              if (canManage(r)) IconButton(tooltip: context.tr('removeFromServer'), onPressed: () => removeFromServer(r), icon: const Icon(Icons.delete_outline)),
              if (r.audio.values.any((a) => a.status == 'failed') && widget.group.mayUseAi)
                OutlinedButton.icon(onPressed: () => retry(r), icon: const Icon(Icons.refresh), label: Text(context.tr('retry'))),
            ]),
          ],

          heading('recordingsShared', Icons.cloud_outlined),
          if (serverError != null) note(context.tr('sharedUnavailable', {'error': readableError(serverError!)}), error: true)
          else if (server == null) const LinearProgressIndicator()
          else if (shared.isEmpty) note(context.tr('noSharedRecordings')),
          for (final r in shared) _RecordingCard(recording: r, actions: [
            if (canManage(r)) IconButton(tooltip: context.tr('removeFromServer'), onPressed: () => removeFromServer(r), icon: const Icon(Icons.delete_outline)),
            _progressOr(r, FilledButton.tonalIcon(onPressed: () => download(r), icon: const Icon(Icons.download), label: Text(context.tr('download')))),
          ]),
        ])),
    );
  }

  /// [button], or the download progress while [r] is being downloaded.
  Widget _progressOr(Recording r, Widget button) {
    final progress = downloading[r.id];
    if (progress == null) return button;
    return FilledButton.tonalIcon(onPressed: null, label: Text('${(progress * 100).round()}%'), icon: SizedBox.square(dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2, value: progress == 0 ? null : progress)));
  }
}

/// A recording's name, approximate size, date and time, author and audio languages, then [actions].
class _RecordingCard extends StatelessWidget {
  final Recording recording;
  final List<Widget> actions;
  /// A key of a short note under the details, e.g. whether it is also shared.
  final String? badge;
  /// The state of each audio (recordings being processed).
  final String? status;
  const _RecordingCard({required this.recording, required this.actions, this.badge, this.status});
  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = recording.info;
    final details = [
      info.sizeBytes == null ? '? MB' : formatMegabytes(info.sizeBytes!),
      if (info.created != null) formatDateTime(info.created),
      if ((info.author ?? '').isNotEmpty) info.author!,
      context.tr('sentenceCount', {'count': recording.sentenceCount}),
    ].join(' · ');
    return Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 12, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(recording.name, style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(details, style: theme.textTheme.bodySmall),
      if (status != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(status!, style: theme.textTheme.bodySmall)),
      const SizedBox(height: 6),
      Row(children: [
        if (recording.audio.isNotEmpty) Expanded(child: AudioLanguageBadges(languages: recording.audio.keys)) else const Spacer(),
        if (badge != null) Text(context.tr(badge!), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
      ]),
      const SizedBox(height: 8),
      Align(alignment: AlignmentDirectional.centerEnd, child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions)),
    ])));
  }
}
