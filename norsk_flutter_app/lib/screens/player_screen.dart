import 'package:flutter/material.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/audio_cache.dart';
import '../services/sentence_player.dart';
class PlayerScreen extends StatefulWidget {
  final Api api; final String recordingId;
  const PlayerScreen({super.key, required this.api, required this.recordingId});
  @override State<PlayerScreen> createState() => _PlayerScreenState();
}
class _PlayerScreenState extends State<PlayerScreen> {
  Recording? recording; SentencePlayer? player;
  bool busy = true, downloading = false; double progress = 0, speed = 1;
  String? error;
  @override void initState() { super.initState(); load(); }
  @override void dispose() { player?.dispose(); super.dispose(); }
  Future<void> load() async {
    setState(() { busy = true; error = null; });
    try {
      final r = await widget.api.recording(widget.recordingId);
      if (!mounted) return;
      await player?.dispose();
      player = SentencePlayer(r.sentences, () { if (mounted) setState(() {}); });
      setState(() { recording = r; busy = false; });
      final cached = await AudioCache(widget.api).cached(r.id);
      if (cached != null) await player!.open(cached.path);
    } catch (e) { if (mounted) setState(() { error = readableError(e); busy = false; }); }
  }
  Future<void> obtainAndPlay() async {
    if (recording == null || player == null) return;
    try {
      setState(() { downloading = true; progress = 0; });
      final file = await AudioCache(widget.api).obtain(recording!.id, (v) { if (mounted) setState(() => progress = v); });
      if (!mounted) return;
      await player!.open(file.path);
      await player!.playPause();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
    finally { if (mounted) setState(() => downloading = false); }
  }
  Future<void> edit(int i) async {
    final r = recording!; final s = r.sentences[i];
    final t = TextEditingController(text: s.text);
    final start = TextEditingController(text: '${s.startMs}');
    final end = TextEditingController(text: '${s.endMs}');
    final saved = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Edit sentence'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: t, maxLines: 3, decoration: const InputDecoration(labelText: 'Text')),
        TextField(controller: start, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Start (ms)')),
        TextField(controller: end, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'End (ms)')),
      ])), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save'))]));
    if (saved == true) {
      try { await widget.api.editSentence(r.id, i, t.text, int.parse(start.text), int.parse(end.text)); await load(); }
      catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
    }
  }
  Future<void> deleteRecording() async {
    final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Delete recording?'),
      content: const Text('This deletes the recording for everyone in the group.'), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete'))]));
    if (yes != true) return;
    try { await widget.api.deleteRecording(widget.recordingId); await AudioCache(widget.api).clear(widget.recordingId); if (mounted) Navigator.pop(context); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
  }
  @override Widget build(BuildContext context) {
    final r = recording; final p = player;
    return Scaffold(appBar: AppBar(title: Text(r?.name ?? 'Recording'), actions: [
      IconButton(tooltip: 'Refresh transcript', onPressed: load, icon: const Icon(Icons.refresh)),
      PopupMenuButton<String>(onSelected: (v) async {
        try {
          if (v == 'delete') { await deleteRecording(); }
          if (v == 'retry') { await widget.api.transcribe(widget.recordingId); await load(); }
          if (v == 'cache') { await AudioCache(widget.api).clear(widget.recordingId); await p?.audio.stop(); if (mounted) setState(() {}); }
        } catch (e) { if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
      }, itemBuilder: (_) => [const PopupMenuItem(value: 'cache', child: Text('Clear offline audio')),
        const PopupMenuItem(value: 'retry', child: Text('Retry transcription (uploader/admin)')),
        const PopupMenuItem(value: 'delete', child: Text('Delete (admin only)'))])]),
      body: busy ? const Center(child: CircularProgressIndicator()) : error != null ? Center(child: Text(error!)) : r == null || p == null ? const SizedBox() :
      Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: Column(children: [
          Text('${r.status} · ${(r.durationSeconds/60).toStringAsFixed(1)} minutes · ${r.sentences.length} sentences'),
          if (r.error != null) Text(r.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (downloading) LinearProgressIndicator(value: progress == 0 ? null : progress),
          const SizedBox(height: 10),
          StreamBuilder<Duration>(stream: p.audio.positionStream, builder: (ctx,snap) {
            final ms = snap.data?.inMilliseconds ?? 0;
            return Text('${(ms/1000).toStringAsFixed(1)}s / ${r.durationSeconds.toStringAsFixed(1)}s');
          }),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: r.sentences.isEmpty ? null : p.previous, icon: const Icon(Icons.skip_previous), iconSize: 38),
            IconButton(onPressed: downloading ? null : () async {
              final f = await AudioCache(widget.api).cached(r.id);
              if (f != null && p.audio.duration != null) { await p.playPause(); }
              else { await obtainAndPlay(); }
            }, icon: Icon(p.audio.playing ? Icons.pause_circle : Icons.play_circle), iconSize: 62),
            IconButton(onPressed: r.sentences.isEmpty ? null : p.next, icon: const Icon(Icons.skip_next), iconSize: 38),
          ]),
          Row(children: [const Text('Repeats'), Expanded(child: Slider(value: p.repeats.toDouble(), min: 1, max: 20, divisions: 19,
            label: '${p.repeats}', onChanged: (v) => p.setRepeats(v.round()))), Text('${p.repeats}×')]),
          Row(children: [const Text('Speed'), Expanded(child: Slider(value: speed, min: 0.5, max: 1.5, divisions: 10,
            label: '${speed.toStringAsFixed(1)}×', onChanged: (v) async { setState(() => speed = v); await p.setSpeed(v); })), Text('${speed.toStringAsFixed(1)}×')]),
          Text('Sentence ${r.sentences.isEmpty ? 0 : p.index+1}/${r.sentences.length} · Repeat ${p.iteration}/${p.repeats}'),
        ])), const Divider(height: 1),
        Expanded(child: r.sentences.isEmpty ? Center(child: Text(r.status == 'pending' || r.status == 'processing'
          ? 'Transcription in progress. Tap refresh later.' : 'No sentences available.')) :
          ListView.builder(itemCount: r.sentences.length, itemBuilder: (ctx,i) {
            final s = r.sentences[i]; final selected = p.index == i;
            return ListTile(selected: selected, selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
              leading: Text('${i+1}'), title: Text(s.text), subtitle: Text('${(s.startMs/1000).toStringAsFixed(2)}–${(s.endMs/1000).toStringAsFixed(2)}s'),
              trailing: IconButton(tooltip: 'Edit (uploader/admin)', icon: const Icon(Icons.edit_outlined), onPressed: () => edit(i)),
              onTap: () => p.select(i));
          })),
      ]));
  }
}
