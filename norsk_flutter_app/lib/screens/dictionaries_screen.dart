import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/api.dart';
import '../services/dictionaries.dart';
import '../services/document_store.dart' show formatBytes;

/// The dictionaries the server offers, to download, update or remove on this device. Without a
/// connection it still lists the saved ones. Leaving the page cancels running downloads.
class DictionariesScreen extends StatefulWidget {
  final Dictionaries dictionaries;
  const DictionariesScreen({super.key, required this.dictionaries});
  @override State<DictionariesScreen> createState() => _DictionariesScreenState();
}
class _DictionariesScreenState extends State<DictionariesScreen> {
  List<DictionaryInfo> remote = const [];
  Map<String, int> local = const {};
  Object? error;
  bool loading = true, updatingAll = false;
  /// The running downloads, by language.
  final progress = <String, double>{};
  final cancels = <String, CancelToken>{};

  List<DictionaryStatus> get rows => DictionaryStatus.merge(remote, local);

  @override void initState() { super.initState(); load(); }
  @override void dispose() { for (final c in cancels.values) { c.cancel(); } super.dispose(); }

  /// Reads both lists; if one can't be read, the other is still shown.
  Future<void> load() async {
    setState(() { loading = true; error = null; });
    List<DictionaryInfo>? listed; Map<String, int>? saved; Object? failure;
    try { listed = await widget.dictionaries.available(); } catch (e) { failure = e; }
    try { saved = await widget.dictionaries.localSizes(); } catch (e) { failure ??= e; }
    if (!mounted) return;
    setState(() { remote = listed ?? remote; local = saved ?? local; error = failure; loading = false; });
  }

  void showError(Object e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }

  /// Downloads or updates one dictionary; a language already downloading is left alone.
  Future<void> download(DictionaryInfo d) async {
    if (progress.containsKey(d.lang)) return;
    final cancel = CancelToken();
    setState(() { progress[d.lang] = 0; cancels[d.lang] = cancel; });
    try {
      await widget.dictionaries.download(d, (v) { if (mounted) setState(() => progress[d.lang] = v); }, cancel: cancel);
      final saved = await widget.dictionaries.localSizes();
      if (mounted) setState(() => local = saved);
    } catch (e) {
      if (!cancel.isCancelled) showError(e);
    } finally {
      cancels.remove(d.lang);
      if (mounted) setState(() => progress.remove(d.lang));
    }
  }

  /// One after the other; one that fails doesn't stop the rest.
  Future<void> updateAll() async {
    setState(() => updatingAll = true);
    for (final row in rows) {
      if (!mounted) return;
      if (row.needsUpdate) await download(row.remote!);
    }
    if (mounted) setState(() => updatingAll = false);
  }

  Future<void> remove(String lang) async {
    try {
      await widget.dictionaries.remove(lang);
      final saved = await widget.dictionaries.localSizes();
      if (mounted) setState(() => local = saved);
    } catch (e) { showError(e); }
  }

  Widget rowCard(DictionaryStatus row) {
    final value = progress[row.lang], remote = row.remote;
    return Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 12, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(languageNames[row.lang] ?? row.lang.toUpperCase(), style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 2),
      Text(formatBytes(row.size)),
      const SizedBox(height: 8),
      if (value != null) LinearProgressIndicator(value: value)
      else Align(alignment: AlignmentDirectional.centerEnd, child: Wrap(spacing: 8, runSpacing: 8, children: [
        if (row.downloaded) OutlinedButton.icon(onPressed: () => remove(row.lang), icon: const Icon(Icons.delete_outline), label: Text(context.tr('remove'))),
        if (row.needsUpdate) FilledButton.icon(onPressed: () => download(remote!), icon: const Icon(Icons.sync), label: Text(context.tr('update'))),
        if (!row.downloaded && remote != null) FilledButton.icon(onPressed: () => download(remote), icon: const Icon(Icons.download), label: Text(context.tr('download'))),
      ])),
    ])));
  }

  @override Widget build(BuildContext context) {
    final rows = this.rows, failure = error;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('dictionaries')), actions: [
        IconButton(tooltip: context.tr('refresh'), onPressed: loading ? null : load, icon: const Icon(Icons.refresh)),
      ]),
      body: loading && rows.isEmpty ? const Center(child: CircularProgressIndicator())
        : Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: ListView(padding: const EdgeInsets.all(12), children: [
          if (failure != null) Padding(padding: const EdgeInsets.all(4),
            child: Text(readableError(failure), style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (rows.any((r) => r.needsUpdate)) Padding(padding: const EdgeInsets.only(bottom: 8),
            child: FilledButton.icon(onPressed: updatingAll ? null : updateAll, icon: const Icon(Icons.sync), label: Text(context.tr('updateAll')))),
          if (rows.isEmpty && failure == null) Padding(padding: const EdgeInsets.all(24),
            child: Text(context.tr('noDictionaries'), textAlign: TextAlign.center)),
          for (final row in rows) rowCard(row),
        ]))),
    );
  }
}
