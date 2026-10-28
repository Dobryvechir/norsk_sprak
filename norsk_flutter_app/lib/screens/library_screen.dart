import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import 'player_screen.dart';
import 'upload_screen.dart';
class LibraryScreen extends StatefulWidget {
  final Api api; final StudyGroup group;
  const LibraryScreen({super.key, required this.api, required this.group});
  @override State<LibraryScreen> createState() => _LibraryScreenState();
}
class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<Recording>> future;
  @override void initState() { super.initState(); refresh(); }
  void refresh() => setState(() { future = widget.api.recordings(widget.group.id); });
  Future<void> upload() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => UploadScreen(api: widget.api, group: widget.group)));
    refresh();
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.group.name), actions: [
      IconButton(tooltip: context.tr('refresh'), onPressed: refresh, icon: const Icon(Icons.refresh))]),
    floatingActionButton: FloatingActionButton.extended(onPressed: upload, icon: const Icon(Icons.upload_file), label: Text(context.tr('upload'))),
    body: FutureBuilder<List<Recording>>(future: future, builder: (ctx, snap) {
      if (!snap.hasData) return Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator());
      final items = [...snap.data!]..sort((a,b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (items.isEmpty) return Center(child: Text(context.tr('noRecordings')));
      return RefreshIndicator(onRefresh: () async { refresh(); await future; }, child: ListView.builder(
        itemCount: items.length, itemBuilder: (ctx,i) {
          final r = items[i]; final languages = orderedLanguages(r.audio.keys);
          final ready = r.audio.values.any((a) => a.status == 'ready');
          // One part per audio language, e.g. "NB 3.2 min · ready", then the sentence count.
          final parts = [for (final l in languages) '${l.toUpperCase()} ${context.tr('audioSummary', {
            'minutes': (r.audio[l]!.durationSeconds/60).toStringAsFixed(1), 'status': context.trStatus(r.audio[l]!.status)})}'];
          final errors = [for (final l in languages) if (r.audio[l]!.error != null) '${l.toUpperCase()}: ${r.audio[l]!.error}'];
          return ListTile(leading: Icon(ready ? Icons.play_circle_outline : Icons.hourglass_top),
            title: Text(r.name), subtitle: Text([[...parts, context.tr('sentenceCount', {'count': r.sentenceCount})].join(' · '), ...errors].join('\n')),
            isThreeLine: errors.isNotEmpty, trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(api: widget.api, group: widget.group, recordingId: r.id))));
        }));
    }),
  );
}
