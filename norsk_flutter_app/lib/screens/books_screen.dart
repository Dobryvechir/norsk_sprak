import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/settings.dart';
import 'chapters_screen.dart';
/// The books the user may see. Opening a book shows its sections.
class BooksScreen extends StatelessWidget {
  final Api api;
  const BooksScreen({super.key, required this.api});
  @override Widget build(BuildContext context) => CatalogScreen<Book>(
    api: api, title: context.tr('menuBooks'), searchHintKey: 'searchBooks', emptyKey: 'noBooks',
    load: (query, page, pageSize) => api.books(query, page, pageSize, AppSettings.instance.uiLanguage),
    onOpen: (book) => Navigator.push(context, MaterialPageRoute(builder: (_) => SectionsScreen(api: api, book: book))));
}
/// The sections of [book] the user may see. Opening a section shows its chapters.
class SectionsScreen extends StatelessWidget {
  final Api api; final Book book;
  const SectionsScreen({super.key, required this.api, required this.book});
  @override Widget build(BuildContext context) => CatalogScreen<Section>(
    api: api, title: book.displayName(AppSettings.instance.uiLanguage), searchHintKey: 'searchSections', emptyKey: 'noSections',
    load: (query, page, pageSize) => api.sections(book.id, query, page, pageSize, AppSettings.instance.uiLanguage),
    onOpen: (section) => Navigator.push(context, MaterialPageRoute(builder: (_) => ChaptersScreen(api: api, section: section))));
}
/// A read-only, searchable, paged grid of book-like cards (books or sections).
class CatalogScreen<T extends Book> extends StatefulWidget {
  final Api api; final String title, searchHintKey, emptyKey;
  final Future<PagedList<T>> Function(String query, int page, int pageSize) load;
  final void Function(T item) onOpen;
  const CatalogScreen({super.key, required this.api, required this.title, required this.searchHintKey,
    required this.emptyKey, required this.load, required this.onOpen});
  @override State<CatalogScreen<T>> createState() => _CatalogScreenState<T>();
}
class _CatalogScreenState<T extends Book> extends State<CatalogScreen<T>> {
  static const pageSize = 20;
  final search = TextEditingController();
  Timer? _debounce;
  int page = 1;
  late Future<PagedList<T>> future;
  @override void initState() { super.initState(); load(); }
  @override void dispose() { _debounce?.cancel(); search.dispose(); super.dispose(); }
  void load() => setState(() { future = widget.load(search.text.trim(), page, pageSize); });
  /// Searches once typing pauses, starting again from the first page.
  void onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () { page = 1; load(); });
  }
  void goTo(int p) { page = p; load(); }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title), actions: [IconButton(tooltip: context.tr('refresh'), onPressed: load, icon: const Icon(Icons.refresh))]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: TextField(controller: search, onChanged: onSearchChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(hintText: context.tr(widget.searchHintKey), prefixIcon: const Icon(Icons.search), border: const OutlineInputBorder(),
          suffixIcon: search.text.isEmpty ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () { search.clear(); onSearchChanged(''); })))),
      Expanded(child: FutureBuilder<PagedList<T>>(future: future, builder: (ctx, snap) {
        if (!snap.hasData) return Center(child: snap.hasError ? Text(readableError(snap.error!)) : const CircularProgressIndicator());
        final result = snap.data!;
        return Column(children: [
          Expanded(child: result.items.isEmpty ? Center(child: Text(context.tr(widget.emptyKey))) : GridView.builder(
            padding: const EdgeInsets.all(16), itemCount: result.items.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240, mainAxisExtent: 290, crossAxisSpacing: 12, mainAxisSpacing: 12),
            itemBuilder: (ctx, i) => BookCard(api: widget.api, book: result.items[i], onTap: () => widget.onOpen(result.items[i])))),
          Pager(page: page, pages: result.pages, onPage: goTo),
        ]);
      })),
    ]),
  );
}
/// Previous/next page buttons with "Page x of y"; nothing when everything fits on one page.
class Pager extends StatelessWidget {
  final int page, pages; final ValueChanged<int> onPage;
  const Pager({super.key, required this.page, required this.pages, required this.onPage});
  @override Widget build(BuildContext context) => pages <= 1 ? const SizedBox.shrink() : SafeArea(top: false,
    child: Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      IconButton(tooltip: context.tr('previousPage'), onPressed: page > 1 ? () => onPage(page - 1) : null, icon: const Icon(Icons.chevron_left)),
      Text(context.tr('pageOf', {'page': page, 'pages': pages})),
      IconButton(tooltip: context.tr('nextPage'), onPressed: page < pages ? () => onPage(page + 1) : null, icon: const Icon(Icons.chevron_right)),
    ])));
}
/// Small badges with the codes of [languages] (in the app's language order), after a headphones icon.
class AudioLanguageBadges extends StatelessWidget {
  final Iterable<String> languages;
  const AudioLanguageBadges({super.key, required this.languages});
  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Tooltip(message: context.tr('audioLanguage'), child: const Icon(Icons.headphones, size: 16)),
      for (final l in orderedLanguages(languages)) Tooltip(message: languageNames[l] ?? l, child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        child: Text(l.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer)))),
    ]);
  }
}
/// A book's (or section's) icon, name (in the UI language when available), author and audio languages.
class BookCard extends StatelessWidget {
  final Api api; final Book book; final VoidCallback? onTap;
  const BookCard({super.key, required this.api, required this.book, this.onTap});
  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    context.tr('menuBooks'); // rebuild when the UI language changes, so the name follows it
    final placeholder = ColoredBox(color: theme.colorScheme.primaryContainer,
      child: Icon(Icons.menu_book, size: 48, color: theme.colorScheme.onPrimaryContainer));
    return Card(clipBehavior: Clip.antiAlias, child: InkWell(onTap: onTap, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: book.icon.isEmpty ? placeholder
        : Image.network(api.resolveUrl(book.icon), fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder)),
      Padding(padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(book.displayName(AppSettings.instance.uiLanguage), style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (book.author.isNotEmpty) Text(book.author, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 6),
        AudioLanguageBadges(languages: book.audioLanguages),
      ])),
    ])));
  }
}
