import 'package:flutter/material.dart';
import '../models/entities.dart';
import '../services/api.dart';
import 'player_screen.dart';
import 'upload_screen.dart';
import 'admin_screen.dart';
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
      IconButton(tooltip: 'Refresh', onPressed: refresh, icon: const Icon(Icons.refresh)),
      IconButton(tooltip: 'Group administration', onPressed: () => Navigator.push(context,
        MaterialPageRoute(builder: (_) => AdminScreen(api: widget.api, group: widget.group))), icon: const Icon(Icons.admin_panel_settings))]),
    floatingActionButton: FloatingActionButton.extended(onPressed: upload, icon: const Icon(Icons.upload_file), label: const Text('Upload')),
    body: FutureBuilder<List<Recording>>(future: future, builder: (ctx, snap) {
      if (!snap.hasData) return Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator());
      final items = [...snap.data!]..sort((a,b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (items.isEmpty) return const Center(child: Text('No recordings yet.'));
      return RefreshIndicator(onRefresh: () async { refresh(); await future; }, child: ListView.builder(
        itemCount: items.length, itemBuilder: (ctx,i) {
          final r = items[i]; final ready = r.status == 'ready' || r.status == 'completed';
          return ListTile(leading: Icon(ready ? Icons.play_circle_outline : Icons.hourglass_top),
            title: Text(r.name), subtitle: Text('${(r.durationSeconds/60).toStringAsFixed(1)} min · ${r.status} · ${r.sentences.length} sentences${r.error == null ? '' : '\n${r.error}'}'),
            isThreeLine: r.error != null, trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(api: widget.api, recordingId: r.id))));
        }));
    }),
  );
}
