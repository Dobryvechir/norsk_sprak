import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/offline_chapters.dart';
import '../services/sentence_player.dart';
import '../services/settings.dart';
import 'chapters_screen.dart';
/// Plays a saved chapter line by line: each line is its part of the audio (startMs–endMs of that
/// language's timings), shown with the same texts as View. The audio is the saved copy (on web, in the
/// browser's storage). A chapter saved on web by an older version has no audio saved: it is then played
/// from the audio's own `url` if it has one, else fetched from the server's audio endpoint into memory.
class ChapterPlayerScreen extends StatefulWidget {
  final Api api; final Recording chapter;
  const ChapterPlayerScreen({super.key, required this.api, required this.chapter});
  @override State<ChapterPlayerScreen> createState() => _ChapterPlayerScreenState();
}
class _ChapterPlayerScreenState extends State<ChapterPlayerScreen> {
  SentencePlayer? player;
  /// The language of the audio being played.
  String? language;
  /// Progress (0–1) while the audio is loading (on web: fetched), else null.
  double? loading;
  String? error;
  double speed = 1;
  /// On web: the `blob:` URL of the saved audio being played, released when no longer needed.
  String? objectUrl;
  /// The languages whose audio has line timings.
  late final List<String> languages = orderedLanguages(widget.chapter.audio.keys.where((l) => widget.chapter.audio[l]!.startMs.isNotEmpty));
  @override void initState() {
    super.initState();
    final preferred = AppSettings.instance.audioLanguage;
    final first = languages.contains(preferred) ? preferred : languages.firstOrNull;
    if (first != null) openAudio(first);
  }
  @override void dispose() { player?.dispose(); releaseObjectUrl(); super.dispose(); }
  void releaseObjectUrl() { final url = objectUrl; objectUrl = null; if (url != null) OfflineChapters.releaseWebAudioUrl(url); }
  void changed() { if (mounted) setState(() {}); }
  /// Switches to [language]'s audio, staying on the same line.
  Future<void> openAudio(String language) async {
    final r = widget.chapter;
    final old = player; final index = old?.index ?? 0;
    await old?.dispose();
    releaseObjectUrl();
    final p = SentencePlayer(r.timedSentences(language), changed);
    if (!mounted) { await p.dispose(); return; }
    setState(() { player = p; this.language = language; error = null; loading = 0; });
    bool current() => mounted && player == p;
    try {
      final saved = kIsWeb ? await OfflineChapters(widget.api).webAudioUrl(r, language) : null;
      final external = kIsWeb ? widget.api.externalAudioUrl(r, language) : null;
      if (saved != null) {
        if (!current()) { OfflineChapters.releaseWebAudioUrl(saved); return; }
        objectUrl = saved;
        await p.openUri(Uri.parse(saved));
      } else if (external != null) {
        // Web, audio not saved but with its own URL: the browser plays it straight from there.
        await p.openUri(Uri.parse(external));
      } else if (kIsWeb) {
        final (bytes, type) = await widget.api.audioBytes(r, language, (v) { if (current()) setState(() => loading = v); });
        if (!current()) return;
        await p.openUri(Uri.dataFromBytes(bytes, mimeType: type ?? 'audio/mpeg'));
      } else {
        final file = await OfflineChapters(widget.api).audioFile(r, language);
        if (!current()) return;
        if (file == null) { setState(() => error = context.tr('audioNotSaved')); return; }
        await p.open(file.path);
      }
      if (current() && p.sentences.isNotEmpty) await p.select(index.clamp(0, p.sentences.length - 1));
    } catch (e) { if (current()) setState(() => error = readableError(e)); }
    finally { if (current()) setState(() => loading = null); }
  }
  @override Widget build(BuildContext context) {
    final r = widget.chapter; final p = player; final theme = Theme.of(context);
    final ready = p != null && loading == null && error == null;
    return Scaffold(appBar: AppBar(title: Text(r.name), actions: [
      if (languages.length > 1) PopupMenuButton<String>(tooltip: context.tr('audioLanguage'), onSelected: openAudio,
        itemBuilder: (_) => [for (final l in languages) CheckedPopupMenuItem(value: l, checked: l == language, child: Text(languageNames[l] ?? l))],
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
          const Icon(Icons.record_voice_over), const SizedBox(width: 4), Text(language?.toUpperCase() ?? '')]))),
    ]),
      body: p == null || p.sentences.isEmpty ? Center(child: Text(context.tr('noSentences'))) : SafeArea(child: Column(children: [
        if (loading != null) LinearProgressIndicator(value: loading == 0 ? null : loading),
        if (error != null) Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Text(error!, style: TextStyle(color: theme.colorScheme.error))),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24),
          child: ChapterLine(chapter: r, index: p.index, total: p.sentences.length, language: language))),
        IconButton(tooltip: context.tr('play'), iconSize: 62, onPressed: ready ? p.playPause : null,
          icon: Icon(p.audio.playing ? Icons.pause_circle : Icons.play_circle)),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          Row(children: [Text(context.tr('repeats')), Expanded(child: Slider(value: p.repeats.toDouble(), min: 1, max: 20, divisions: 19,
            label: '${p.repeats}', onChanged: (v) => p.setRepeats(v.round()))), Text('${p.repeats}×')]),
          Row(children: [Text(context.tr('speed')), Expanded(child: Slider(value: speed, min: 0.5, max: 1.5, divisions: 10,
            label: '${speed.toStringAsFixed(1)}×', onChanged: (v) async { setState(() => speed = v); await p.setSpeed(v); })), Text('${speed.toStringAsFixed(1)}×')]),
        ])),
        LineNavigation(onPrevious: loading == null && p.index > 0 ? p.previous : null,
          onNext: loading == null && p.index < p.sentences.length - 1 ? p.next : null),
      ])));
  }
}
