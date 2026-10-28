import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/audio_cache.dart';
import '../services/sentence_player.dart';
import '../services/settings.dart';
import 'upload_screen.dart';
/// Plays one language's audio of a recording sentence by sentence, showing the texts in the chosen text languages.
/// Also plays book chapters ([PlayerScreen.chapter]), which are read-only: no editing, uploading or deleting.
class PlayerScreen extends StatefulWidget {
  final Api api; final StudyGroup? group; final String recordingId; final bool isChapter;
  const PlayerScreen({super.key, required this.api, required StudyGroup this.group, required this.recordingId}) : isChapter = false;
  const PlayerScreen.chapter({super.key, required this.api, required String chapterId}) : group = null, recordingId = chapterId, isChapter = true;
  @override State<PlayerScreen> createState() => _PlayerScreenState();
}
class _PlayerScreenState extends State<PlayerScreen> {
  Recording? recording; SentencePlayer? player;
  /// The language of the audio being played.
  String? audioLanguage;
  bool busy = true, downloading = false; double progress = 0, speed = 1;
  String? error;
  @override void initState() { super.initState(); load(); }
  @override void dispose() { player?.dispose(); super.dispose(); }
  Future<void> load() async {
    setState(() { busy = true; error = null; });
    try {
      final r = await (widget.isChapter ? widget.api.chapter(widget.recordingId) : widget.api.recording(widget.recordingId));
      if (!mounted) return;
      // Keep the language being played; otherwise the preferred audio language, otherwise the first available.
      final available = orderedLanguages(r.audio.keys);
      final preferred = AppSettings.instance.audioLanguage;
      final language = available.contains(audioLanguage) ? audioLanguage
        : available.contains(preferred) ? preferred : available.firstOrNull;
      recording = r;
      await openAudio(language);
    } catch (e) { if (mounted) setState(() { error = readableError(e); busy = false; }); }
  }
  /// Switches the player to [language]'s audio of the loaded recording.
  Future<void> openAudio(String? language) async {
    final r = recording!;
    await player?.dispose();
    player = SentencePlayer(language == null ? const [] : r.timedSentences(language), () { if (mounted) setState(() {}); });
    setState(() { audioLanguage = language; busy = false; });
    if (language == null) return;
    final cached = await AudioCache(widget.api).cached(r, language);
    if (cached != null && mounted && audioLanguage == language) await player!.open(cached.path);
  }
  Future<void> obtainAndPlay() async {
    final r = recording, language = audioLanguage;
    if (r == null || language == null || player == null) return;
    try {
      setState(() { downloading = true; progress = 0; });
      final file = await AudioCache(widget.api).obtain(r, language, (v) { if (mounted) setState(() => progress = v); });
      if (!mounted || audioLanguage != language) return;
      await player!.open(file.path);
      await player!.playPause();
    } catch (e) { showError(e); }
    finally { if (mounted) setState(() => downloading = false); }
  }
  void showError(Object e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
  /// Languages whose text is shown for each sentence: the chosen text languages that have text,
  /// or the audio's own language when none of them has.
  List<String> shownLanguages(Recording r) {
    final chosen = orderedLanguages(AppSettings.instance.textLanguages).where((l) => r.sentences[l]?.isNotEmpty == true).toList();
    return chosen.isNotEmpty || audioLanguage == null ? chosen : [audioLanguage!];
  }
  Future<void> edit(int i) async {
    final r = recording!; final language = audioLanguage!; final s = player!.sentences[i];
    // Text fields for the audio language and every chosen text language; timing for the audio language.
    final languages = orderedLanguages({language, ...AppSettings.instance.textLanguages});
    final texts = {for (final l in languages) l: TextEditingController(text: r.text(l, i))};
    final start = TextEditingController(text: '${s.startMs}');
    final end = TextEditingController(text: '${s.endMs}');
    final saved = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: Text(context.tr('editSentence')),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final l in languages) TextField(controller: texts[l], maxLines: 3, minLines: 1,
          decoration: InputDecoration(labelText: context.tr('textIn', {'language': languageNames[l]}))),
        TextField(controller: start, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.tr('startMs'))),
        TextField(controller: end, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.tr('endMs'))),
      ])), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.tr('save')))]));
    if (saved != true) return;
    try {
      for (final l in languages) {
        final text = texts[l]!.text.trim();
        if (text.isNotEmpty && text != r.text(l, i)) await widget.api.editSentence(r.id, l, i, text: text);
      }
      final startMs = int.parse(start.text.trim()), endMs = int.parse(end.text.trim());
      if (startMs != s.startMs || endMs != s.endMs) await widget.api.editSentence(r.id, language, i, start: startMs, end: endMs);
      await load();
    } catch (e) { showError(e); }
  }
  Future<void> deleteRecording() async {
    final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: Text(context.tr('deleteRecordingQuestion')),
      content: Text(context.tr('deleteRecordingInfo')), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.tr('delete')))]));
    if (yes != true) return;
    try { await widget.api.deleteRecording(widget.recordingId); await AudioCache(widget.api).clear(widget.recordingId); if (mounted) Navigator.pop(context); }
    catch (e) { showError(e); }
  }
  Future<void> addAudio() async {
    final added = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => UploadScreen(api: widget.api, group: widget.group!, recording: recording)));
    if (added == true) await load();
  }
  @override Widget build(BuildContext context) {
    final r = recording; final p = player; final language = audioLanguage;
    final audio = r == null || language == null ? null : r.audio[language];
    return Scaffold(appBar: AppBar(title: Text(r?.name ?? context.tr('recording')), actions: [
      if (r != null && r.audio.length > 1) PopupMenuButton<String>(tooltip: context.tr('audioLanguage'),
        onSelected: (l) async { await openAudio(l); },
        itemBuilder: (_) => [for (final l in orderedLanguages(r.audio.keys))
          CheckedPopupMenuItem(value: l, checked: l == language, child: Text('${languageNames[l]} · ${context.trStatus(r.audio[l]!.status)}'))],
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
          const Icon(Icons.record_voice_over), const SizedBox(width: 4), Text(language?.toUpperCase() ?? '')]))),
      IconButton(tooltip: context.tr('refreshTranscript'), onPressed: load, icon: const Icon(Icons.refresh)),
      PopupMenuButton<String>(onSelected: (v) async {
        try {
          if (v == 'delete') { await deleteRecording(); }
          if (v == 'add') { await addAudio(); }
          if (v == 'retry' && language != null) { await widget.api.transcribe(widget.recordingId, language); await load(); }
          if (v == 'cache' && r != null) { await AudioCache(widget.api).clear(AudioCache.cacheId(r)); await p?.audio.stop(); if (mounted) setState(() {}); }
        } catch (e) { showError(e); }
      }, itemBuilder: (_) => [PopupMenuItem(value: 'cache', child: Text(context.tr('clearOfflineAudio'))),
        if (!widget.isChapter) ...[
          PopupMenuItem(value: 'add', child: Text(context.tr('addAudioLanguage'))),
          PopupMenuItem(value: 'retry', child: Text(context.tr('retryTranscription'))),
          PopupMenuItem(value: 'delete', child: Text(context.tr('deleteAdminOnly'))),
        ]])]),
      body: busy ? const Center(child: CircularProgressIndicator()) : error != null ? Center(child: Text(error!)) : r == null || p == null || audio == null ? const SizedBox() :
      Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: Column(children: [
          Text('${languageNames[language]} · ${context.tr('playerSummary', {'status': context.trStatus(audio.status), 'minutes': (audio.durationSeconds/60).toStringAsFixed(1), 'count': p.sentences.length})}'),
          if (audio.error != null) Text(audio.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (downloading) LinearProgressIndicator(value: progress == 0 ? null : progress),
          const SizedBox(height: 10),
          StreamBuilder<Duration>(stream: p.audio.positionStream, builder: (ctx,snap) {
            final ms = snap.data?.inMilliseconds ?? 0;
            return Text('${(ms/1000).toStringAsFixed(1)}s / ${audio.durationSeconds.toStringAsFixed(1)}s');
          }),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: p.sentences.isEmpty ? null : p.previous, icon: const Icon(Icons.skip_previous), iconSize: 38),
            IconButton(onPressed: downloading ? null : () async {
              final f = await AudioCache(widget.api).cached(r, language!);
              if (f != null && p.audio.duration != null) { await p.playPause(); }
              else { await obtainAndPlay(); }
            }, icon: Icon(p.audio.playing ? Icons.pause_circle : Icons.play_circle), iconSize: 62),
            IconButton(onPressed: p.sentences.isEmpty ? null : p.next, icon: const Icon(Icons.skip_next), iconSize: 38),
          ]),
          Row(children: [Text(context.tr('repeats')), Expanded(child: Slider(value: p.repeats.toDouble(), min: 1, max: 20, divisions: 19,
            label: '${p.repeats}', onChanged: (v) => p.setRepeats(v.round()))), Text('${p.repeats}×')]),
          Row(children: [Text(context.tr('speed')), Expanded(child: Slider(value: speed, min: 0.5, max: 1.5, divisions: 10,
            label: '${speed.toStringAsFixed(1)}×', onChanged: (v) async { setState(() => speed = v); await p.setSpeed(v); })), Text('${speed.toStringAsFixed(1)}×')]),
          Text(context.tr('sentenceProgress', {'index': p.sentences.isEmpty ? 0 : p.index+1, 'total': p.sentences.length, 'iteration': p.iteration, 'repeats': p.repeats})),
        ])), const Divider(height: 1),
        Expanded(child: p.sentences.isEmpty ? Center(child: Text(context.tr(audio.isTranscribing ? 'transcriptionInProgress' : 'noSentences'))) :
          Builder(builder: (context) {
            final shown = shownLanguages(r);
            return ListView.builder(itemCount: p.sentences.length, itemBuilder: (ctx,i) {
              final s = p.sentences[i]; final selected = p.index == i;
              // With several languages, prefix each line with its code.
              final lines = [for (final l in shown) if (r.text(l, i).isNotEmpty) shown.length > 1 ? '${l.toUpperCase()}  ${r.text(l, i)}' : r.text(l, i)];
              return ListTile(selected: selected, selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
                leading: Text('${i+1}'), title: Text(lines.join('\n')), subtitle: Text('${(s.startMs/1000).toStringAsFixed(2)}–${(s.endMs/1000).toStringAsFixed(2)}s'),
                trailing: widget.isChapter ? null : IconButton(tooltip: context.tr('editUploaderAdmin'), icon: const Icon(Icons.edit_outlined), onPressed: () => edit(i)),
                onTap: () => p.select(i));
            });
          })),
      ]));
  }
}
