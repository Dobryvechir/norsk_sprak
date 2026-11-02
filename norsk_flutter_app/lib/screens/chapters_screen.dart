import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/offline_chapters.dart';
import '../services/settings.dart';
import 'books_screen.dart';
import 'chapter_player_screen.dart';
/// The chapters of [section], paged. A chapter not saved on this device has a Download button;
/// a saved one has View (read it line by line) and Play, which use the saved copy.
class ChaptersScreen extends StatefulWidget {
  final Api api; final Section section;
  const ChaptersScreen({super.key, required this.api, required this.section});
  @override State<ChaptersScreen> createState() => _ChaptersScreenState();
}
class _ChaptersScreenState extends State<ChaptersScreen> {
  static const pageSize = 20;
  int page = 1;
  late Future<PagedList<Recording>> future;
  late final offline = OfflineChapters(widget.api);
  /// IDs of the chapters on this page that are saved on this device.
  Set<String> saved = {};
  /// Download progress (0–1) of the chapters being downloaded.
  final downloading = <String, double>{};
  @override void initState() { super.initState(); load(); }
  void load() => setState(() { future = widget.api.chapters(widget.section.id, page, pageSize).then((result) async {
    saved = await offline.saved(result.items.map((c) => c.id));
    return result;
  }); });
  void goTo(int p) { page = p; load(); }
  void open(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  void showError(Object e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
  Future<void> download(Recording chapter) async {
    setState(() => downloading[chapter.id] = 0);
    try {
      await offline.download(chapter.id, (v) { if (mounted) setState(() => downloading[chapter.id] = v); }, section: widget.section);
      saved.add(chapter.id);
    } catch (e) { showError(e); }
    finally { if (mounted) setState(() => downloading.remove(chapter.id)); }
  }
  Future<void> remove(Recording chapter) async {
    final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: Text(context.tr('removeDownload')),
      content: Text(context.tr('removeDownloadQuestion')), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.tr('delete')))]));
    if (yes != true) return;
    try {
      await offline.remove(chapter.id);
      if (mounted) setState(() => saved.remove(chapter.id));
    } catch (e) { showError(e); }
  }
  /// Opens the screen made by [screen] for the saved copy of [chapter].
  Future<void> openSaved(Recording chapter, Widget Function(Recording saved) screen) async {
    try {
      final copy = await offline.load(chapter.id);
      if (!mounted) return;
      if (copy == null) { setState(() => saved.remove(chapter.id)); } else { open(screen(copy)); }
    } catch (e) { showError(e); }
  }
  List<Widget> buttons(Recording chapter) {
    final progress = downloading[chapter.id];
    if (progress != null) {
      return [FilledButton.tonalIcon(onPressed: null, label: Text('${(progress * 100).round()}%'), icon: SizedBox.square(dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2, value: progress == 0 ? null : progress)))];
    }
    if (!saved.contains(chapter.id)) {
      return [FilledButton.tonalIcon(onPressed: () => download(chapter), icon: const Icon(Icons.download), label: Text(context.tr('download')))];
    }
    final playable = chapter.audio.values.any((a) => a.startMs.isNotEmpty);
    return [
      IconButton(tooltip: context.tr('removeDownload'), onPressed: () => remove(chapter), icon: const Icon(Icons.delete_outline)),
      OutlinedButton.icon(onPressed: chapter.sentenceCount == 0 ? null : () => openSaved(chapter, (c) => ChapterViewScreen(chapter: c)),
        icon: const Icon(Icons.article_outlined), label: Text(context.tr('view'))),
      FilledButton.icon(onPressed: playable ? () => openSaved(chapter, (c) => ChapterPlayerScreen(api: widget.api, chapter: c)) : null,
        icon: const Icon(Icons.play_arrow), label: Text(context.tr('play'))),
    ];
  }
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
          return Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 12, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(chapter.name, style: Theme.of(context).textTheme.titleMedium),
            if (chapter.audio.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: AudioLanguageBadges(languages: chapter.audio.keys)),
            const SizedBox(height: 8),
            Align(alignment: AlignmentDirectional.centerEnd, child: Wrap(spacing: 8, runSpacing: 8, children: buttons(chapter))),
          ])));
        })),
        Pager(page: page, pages: result.pages, onPage: goTo),
      ]);
    }),
  );
}
/// A saved chapter one line (sentence) at a time: the line in the study language (the audio language
/// in the settings), with its translations in the other chosen text languages below it.
class ChapterViewScreen extends StatefulWidget {
  final Recording chapter;
  const ChapterViewScreen({super.key, required this.chapter});
  @override State<ChapterViewScreen> createState() => _ChapterViewScreenState();
}
class _ChapterViewScreenState extends State<ChapterViewScreen> {
  int index = 0;
  @override Widget build(BuildContext context) {
    final r = widget.chapter; final count = r.sentenceCount;
    context.tr('view'); // rebuild when the settings change, so the shown languages follow them
    return Scaffold(appBar: AppBar(title: Text(r.name)),
      body: ChapterLine.mainLanguage(r) == null || count == 0 ? Center(child: Text(context.tr('noSentences'))) : SafeArea(child: Column(children: [
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ChapterLine(chapter: r, index: index, total: count))),
        LineNavigation(onPrevious: index > 0 ? () => setState(() => index--) : null,
          onNext: index < count - 1 ? () => setState(() => index++) : null),
      ])));
  }
}
/// Line [index] of a chapter as View and the chapter player show it: "Line x of y", the line in the study
/// language and, below it, its translations in the other chosen text languages.
class ChapterLine extends StatelessWidget {
  final Recording chapter; final int index, total;
  /// Shown as the study language when the chapter has text in it (the player passes its audio's language).
  final String? language;
  const ChapterLine({super.key, required this.chapter, required this.index, required this.total, this.language});
  static bool hasText(Recording r, String language) => r.sentences[language]?.any((t) => t.isNotEmpty) == true;
  /// [preferred] if the chapter has text in it, else the study language (the audio language in the settings);
  /// else the first chosen text language with text, else the first language with text.
  static String? mainLanguage(Recording r, [String? preferred]) {
    final settings = AppSettings.instance;
    final withText = orderedLanguages(r.sentences.keys.where((l) => hasText(r, l)));
    for (final l in [preferred, settings.audioLanguage]) { if (withText.contains(l)) return l; }
    return withText.where(settings.textLanguages.contains).firstOrNull ?? withText.firstOrNull;
  }
  /// The chosen text languages, other than [main], that have text.
  static List<String> translationLanguages(Recording r, String main) =>
    orderedLanguages(AppSettings.instance.textLanguages).where((l) => l != main && hasText(r, l)).toList();
  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final main = mainLanguage(chapter, language);
    Widget line(String language, TextStyle? style) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(languageNames[language] ?? language, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
      const SizedBox(height: 2),
      Text(chapter.text(language, index).isEmpty ? '—' : chapter.text(language, index), style: style),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(context.tr('lineOf', {'index': index + 1, 'total': total}), style: theme.textTheme.labelMedium),
      if (main != null) ...[
        const SizedBox(height: 16),
        line(main, theme.textTheme.headlineSmall),
        for (final l in translationLanguages(chapter, main)) ...[const SizedBox(height: 20), line(l, theme.textTheme.bodyLarge)],
      ],
    ]);
  }
}
/// The Previous line / Next line buttons; a null callback disables its button.
class LineNavigation extends StatelessWidget {
  final VoidCallback? onPrevious, onNext;
  const LineNavigation({super.key, this.onPrevious, this.onNext});
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(16), child: Row(children: [
    Expanded(child: OutlinedButton.icon(onPressed: onPrevious, icon: const Icon(Icons.chevron_left), label: Text(context.tr('previousLine')))),
    const SizedBox(width: 12),
    Expanded(child: FilledButton.icon(onPressed: onNext, icon: const Icon(Icons.chevron_right), label: Text(context.tr('nextLine')))),
  ]));
}
