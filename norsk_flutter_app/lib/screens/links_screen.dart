import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/l10n.dart';
import '../services/doc_links.dart';

/// Named web links, kept only on this device: add, open, edit and delete.
class LinksScreen extends StatefulWidget {
  const LinksScreen({super.key});
  @override State<LinksScreen> createState() => _LinksScreenState();
}

class _LinksScreenState extends State<LinksScreen> {
  late Future<List<DocLink>> future;

  @override void initState() { super.initState(); load(); }
  void load() => setState(() { future = DocLinks.all(); });

  Future<void> edit([DocLink? link]) async {
    final result = await showDialog<(String, String)>(context: context, builder: (_) => _LinkDialog(link: link));
    if (result == null) return;
    final (name, url) = result;
    link == null ? await DocLinks.create(name, url) : await DocLinks.update(DocLink(link.id, name, url));
    load();
  }

  Future<void> delete(DocLink link) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(ctx.tr('linkDeleteQuestion', {'name': link.name})),
      content: Text(link.url),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('delete'))),
      ]));
    if (ok != true) return;
    await DocLinks.delete(link.id);
    load();
  }

  Future<void> open(DocLink link) async {
    var ok = false;
    try { ok = await launchUrl(Uri.parse(link.url), mode: LaunchMode.externalApplication); } catch (_) {}
    if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr('linkOpenFailed', {'url': link.url}))));
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('docLinks'))),
    floatingActionButton: FloatingActionButton.extended(onPressed: edit, icon: const Icon(Icons.add_link), label: Text(context.tr('linkAdd'))),
    body: FutureBuilder<List<DocLink>>(future: future, builder: (ctx, snap) {
      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
      final links = snap.data!;
      if (links.isEmpty) return Center(child: Text(context.tr('linksEmpty')));
      return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88), itemCount: links.length,
        itemBuilder: (_, i) {
          final l = links[i];
          return Card(child: ListTile(
            leading: const Icon(Icons.link),
            title: Text(l.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(l.url, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => open(l),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: context.tr('linkEdit'), onPressed: () => edit(l), icon: const Icon(Icons.edit_outlined)),
              IconButton(tooltip: context.tr('delete'), onPressed: () => delete(l),
                icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error)),
            ]),
          ));
        })));
    }),
  );
}

/// Asks for a link's name and address; returns them, the address normalized (see [normalizeLink]).
class _LinkDialog extends StatefulWidget {
  final DocLink? link;
  const _LinkDialog({this.link});
  @override State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final name = TextEditingController(text: widget.link?.name);
  late final url = TextEditingController(text: widget.link?.url);
  String? nameError, urlError;

  @override void dispose() { name.dispose(); url.dispose(); super.dispose(); }

  void save() {
    final n = name.text.trim(), u = normalizeLink(url.text);
    setState(() {
      nameError = n.isEmpty ? context.tr('mediaNameRequired') : null;
      urlError = u == null ? context.tr('linkUrlInvalid') : null;
    });
    if (nameError == null && u != null) Navigator.pop(context, (n, u));
  }

  @override Widget build(BuildContext context) => AlertDialog(
    title: Text(context.tr(widget.link == null ? 'linkAdd' : 'linkEdit')),
    content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: name, autofocus: true, textInputAction: TextInputAction.next,
        decoration: InputDecoration(labelText: context.tr('mediaName'), errorText: nameError, border: const OutlineInputBorder())),
      const SizedBox(height: 12),
      TextField(controller: url, keyboardType: TextInputType.url, textInputAction: TextInputAction.done, onSubmitted: (_) => save(),
        decoration: InputDecoration(labelText: context.tr('linkUrl'), hintText: 'https://', errorText: urlError, border: const OutlineInputBorder())),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('cancel'))),
      FilledButton(onPressed: save, child: Text(context.tr('save'))),
    ],
  );
}
