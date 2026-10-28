import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/settings.dart';
import 'books_screen.dart';
import 'player_screen.dart';
/// The chapters of [section], paged, each with View (read the text) and Play buttons.
class ChaptersScreen extends StatefulWidget {
  final Api api; final Section section;
  const ChaptersScreen({super.key, required this.api, required this.section});
  @override State<ChaptersScreen> createState() => _ChaptersScreenState();
}
class _ChaptersScreenState extends State<ChaptersScreen> {
  static const pageSize = 20;
  int page = 1;
  late Future<PagedList<Recording>> future;
  @override void initState() { super.initState(); load(); }
  void load() => setState(() { future = widget.api.chapters(widget.section.id, page, pageSize); });
  void goTo(int p) { page = p; load(); }
  void open(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.section.displayName(AppSettings.instance.uiLanguage)), actions: [
      IconButton(tooltip: context.tr('refresh'), onPressed: load, icon: const Icon(Icons.refresh))]),
    body: FutureBuilder<PagedList<Recording>>(future: future, builder: (ctx, snap) {
      if (!snap.hasData) return Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator());
      final result = snap.data!;
      if (result.items.isEmpty) return Center(child: Text(context.tr('noChapters')));
      return Column(children: [
        Expanded(child: ListView.builder(padding: const EdgeInsets.all(12), itemCount: result.items.length, itemBuilder: (ctx, i) {
          final chapter = result.items[i];
          final playable = chapter.audio.values.any((a) => a.startMs.isNotEmpty);
          return Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 12, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(chapter.name, style: Theme.of(context).textTheme.titleMedium),
            if (chapter.audio.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: AudioLanguageBadges(languages: chapter.audio.keys)),
            const SizedBox(height: 8),
            Align(alignment: AlignmentDirectional.centerEnd, child: Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: chapter.sentenceCount == 0 ? null : () => open(ChapterViewScreen(api: widget.api, chapterId: chapter.id)),
                icon: const Icon(Icons.article_outlined), label: Text(context.tr('view'))),
              FilledButton.icon(onPressed: playable ? () => open(PlayerScreen.chapter(api: widget.api, chapterId: chapter.id)) : null,
                icon: const Icon(Icons.play_arrow), label: Text(context.tr('play'))),
            ])),
          ])));
        })),
        Pager(page: page, pages: result.pages, onPage: goTo),
      ]);
    }),
  );
}
/// The text of a chapter, sentence by sentence, in the chosen text languages.
class ChapterViewScreen extends StatefulWidget {
  final Api api; final String chapterId;
  const ChapterViewScreen({super.key, required this.api, required this.chapterId});
  @override State<ChapterViewScreen> createState() => _ChapterViewScreenState();
}
class _ChapterViewScreenState extends State<ChapterViewScreen> {
  late final Future<Recording> future = widget.api.chapter(widget.chapterId);
  /// The chosen text languages that have text; if none has, the audio language, else the first language with text.
  static List<String> shownLanguages(Recording r) {
    final withText = orderedLanguages(r.sentences.keys.where((l) => r.sentences[l]!.any((t) => t.isNotEmpty)));
    final chosen = withText.where(AppSettings.instance.textLanguages.contains).toList();
    if (chosen.isNotEmpty || withText.isEmpty) return chosen;
    final audio = AppSettings.instance.audioLanguage;
    return [withText.contains(audio) ? audio : withText.first];
  }
  @override Widget build(BuildContext context) => FutureBuilder<Recording>(future: future, builder: (ctx, snap) {
    final r = snap.data;
    return Scaffold(appBar: AppBar(title: Text(r?.name ?? '')),
      body: r == null ? Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator()) : Builder(builder: (context) {
        final shown = shownLanguages(r);
        if (shown.isEmpty) return Center(child: Text(context.tr('noSentences')));
        return ListView.separated(padding: const EdgeInsets.all(16), itemCount: r.sentenceCount,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (ctx, i) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 32, child: Text('${i + 1}', style: Theme.of(context).textTheme.labelMedium)),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final l in shown) if (r.text(l, i).isNotEmpty) Text(shown.length > 1 ? '${l.toUpperCase()}  ${r.text(l, i)}' : r.text(l, i),
                style: l == shown.first ? Theme.of(context).textTheme.bodyLarge : Theme.of(context).textTheme.bodyMedium),
            ])),
          ]));
      }));
  });
}
