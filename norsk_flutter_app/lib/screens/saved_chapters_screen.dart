import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/api.dart';
import '../services/offline_chapters.dart';
import '../services/settings.dart';
import 'books_screen.dart';
import 'chapter_player_screen.dart';
import 'chapters_screen.dart';
/// Every chapter saved on this device, with View, Play and Remove. Works without a connection:
/// it reads only what is saved here.
class SavedChaptersScreen extends StatefulWidget {
  final Api api;
  const SavedChaptersScreen({super.key, required this.api});
  @override State<SavedChaptersScreen> createState() => _SavedChaptersScreenState();
}
class _SavedChaptersScreenState extends State<SavedChaptersScreen> {
  late final offline = OfflineChapters(widget.api);
  late Future<List<SavedChapter>> future;
  @override void initState() { super.initState(); load(); }
  void load() => setState(() { future = offline.all(AppSettings.instance.uiLanguage); });
  void open(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  Future<void> remove(SavedChapter saved) async {
    final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: Text(context.tr('removeDownload')),
      content: Text(context.tr('removeDownloadQuestion')), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.tr('delete')))]));
    if (yes != true) return;
    try { await offline.remove(saved.chapter.id); load(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('menuSaved'))),
    body: FutureBuilder<List<SavedChapter>>(future: future, builder: (ctx, snap) {
      if (!snap.hasData) return Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator());
      final items = snap.data!;
      if (items.isEmpty) {
        return Center(child: Padding(padding: const EdgeInsets.all(24),
          child: Text(context.tr('noSavedChapters'), textAlign: TextAlign.center)));
      }
      return ListView.builder(padding: const EdgeInsets.all(12), itemCount: items.length, itemBuilder: (ctx, i) {
        final saved = items[i]; final chapter = saved.chapter;
        final playable = chapter.audio.values.any((a) => a.startMs.isNotEmpty);
        return Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 12, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(saved.title(AppSettings.instance.uiLanguage), style: Theme.of(context).textTheme.titleMedium),
          if (chapter.audio.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: AudioLanguageBadges(languages: chapter.audio.keys)),
          const SizedBox(height: 8),
          Align(alignment: AlignmentDirectional.centerEnd, child: Wrap(spacing: 8, runSpacing: 8, children: [
            IconButton(tooltip: context.tr('removeDownload'), onPressed: () => remove(saved), icon: const Icon(Icons.delete_outline)),
            OutlinedButton.icon(onPressed: chapter.sentenceCount == 0 ? null : () => open(ChapterViewScreen(chapter: chapter)),
              icon: const Icon(Icons.article_outlined), label: Text(context.tr('view'))),
            FilledButton.icon(onPressed: playable ? () => open(ChapterPlayerScreen(api: widget.api, chapter: chapter)) : null,
              icon: const Icon(Icons.play_arrow), label: Text(context.tr('play'))),
          ])),
        ])));
      });
    }),
  );
}
