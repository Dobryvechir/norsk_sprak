import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import '../l10n/l10n.dart';
import '../services/document_store.dart';
import '../services/xlsx_reader.dart';

/// Full screen view of a document on this device: a picture (zoomable; swipe for the others in
/// [names]), a PDF (scrollable, zoomable) or a sheet (as a table, one tab per worksheet).
class DocumentViewScreen extends StatefulWidget {
  final DocFolder folder; final List<String> names; final int index;
  const DocumentViewScreen({super.key, required this.folder, required this.names, required this.index});
  @override State<DocumentViewScreen> createState() => _DocumentViewScreenState();
}

class _DocumentViewScreenState extends State<DocumentViewScreen> {
  late final pages = PageController(initialPage: widget.index);
  late int index = widget.index;

  @override void dispose() { pages.dispose(); super.dispose(); }

  String get name => widget.names[index];

  @override Widget build(BuildContext context) {
    if (widget.folder == DocFolder.pictures) {
      const white = Colors.white;
      return Scaffold(backgroundColor: Colors.black, body: Stack(children: [
        Positioned.fill(child: PageView.builder(controller: pages, itemCount: widget.names.length,
          onPageChanged: (i) => setState(() => index = i),
          itemBuilder: (_, i) => _PictureView(name: widget.names[i]))),
        SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          IconButton(tooltip: context.tr('close'), style: IconButton.styleFrom(backgroundColor: Colors.black45), color: white, iconSize: 28,
            onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          const SizedBox(width: 8),
          Flexible(child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12)),
            child: Text('$name  (${index + 1}/${widget.names.length})', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: white)))),
        ]))),
      ]));
    }
    return Scaffold(
      appBar: AppBar(title: Text(name), leading: IconButton(tooltip: context.tr('close'), onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close))),
      body: widget.folder == DocFolder.pdf ? _PdfView(name: name) : _SheetView(name: name),
    );
  }
}

Widget _message(BuildContext context, String text, {Color? color}) =>
  Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: color))));

class _PictureView extends StatelessWidget {
  final String name;
  const _PictureView({required this.name});
  @override Widget build(BuildContext context) {
    final store = DocumentStore.instance;
    Widget error(BuildContext c) => _message(c, c.tr('mediaCannotShow'), color: Colors.white);
    final Widget image = kIsWeb
      ? FutureBuilder<Uint8List>(future: store.read(DocFolder.pictures, name), builder: (c, snap) => snap.hasError ? error(c)
          : !snap.hasData ? const Center(child: CircularProgressIndicator())
          : Image.memory(snap.data!, fit: BoxFit.contain, errorBuilder: (c, __, ___) => error(c)))
      : FutureBuilder<String?>(future: store.filePath(DocFolder.pictures, name), builder: (c, snap) => !snap.hasData ? const SizedBox.shrink()
          : Image.file(File(snap.data!), fit: BoxFit.contain, errorBuilder: (c, __, ___) => error(c)));
    return InteractiveViewer(maxScale: 8, child: SizedBox.expand(child: image));
  }
}

class _PdfView extends StatelessWidget {
  final String name;
  const _PdfView({required this.name});
  @override Widget build(BuildContext context) {
    final store = DocumentStore.instance;
    final params = PdfViewerParams(
      errorBannerBuilder: (c, error, _, __) => _message(c, '${c.tr('mediaCannotShow')}\n$error'),
    );
    if (kIsWeb) {
      return FutureBuilder<Uint8List>(future: store.read(DocFolder.pdf, name), builder: (c, snap) => snap.hasError ? _message(c, '${snap.error}')
        : !snap.hasData ? const Center(child: CircularProgressIndicator())
        : PdfViewer.data(snap.data!, sourceName: name, params: params));
    }
    return FutureBuilder<String?>(future: store.filePath(DocFolder.pdf, name), builder: (c, snap) => !snap.hasData
      ? const Center(child: CircularProgressIndicator()) : PdfViewer.file(snap.data!, params: params));
  }
}

class _SheetView extends StatefulWidget {
  final String name;
  const _SheetView({required this.name});
  @override State<_SheetView> createState() => _SheetViewState();
}

class _SheetViewState extends State<_SheetView> {
  late final Future<List<XlsxSheet>> sheets = DocumentStore.instance.read(DocFolder.sheets, widget.name).then(readXlsx);

  /// "A", "B", …, "Z", "AA", …
  static String _column(int i) {
    var s = '';
    for (i++; i > 0; i = (i - 1) ~/ 26) { s = String.fromCharCode(65 + (i - 1) % 26) + s; }
    return s;
  }

  @override Widget build(BuildContext context) => FutureBuilder<List<XlsxSheet>>(future: sheets, builder: (c, snap) {
    if (snap.hasError) return _message(c, '${c.tr('mediaCannotShow')}\n${snap.error}');
    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
    final all = snap.data!;
    if (all.isEmpty) return _message(c, c.tr('sheetEmpty'));
    return DefaultTabController(length: all.length, child: Column(children: [
      if (all.length > 1) TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final sheet in all) Tab(text: sheet.name)]),
      Expanded(child: TabBarView(physics: const NeverScrollableScrollPhysics(), children: [for (final sheet in all) _table(c, sheet.rows)])),
    ]));
  });

  Widget _table(BuildContext context, List<List<String>> rows) {
    if (rows.isEmpty) return _message(context, context.tr('sheetEmpty'));
    final theme = Theme.of(context);
    final border = BorderSide(color: theme.dividerColor);
    final header = theme.colorScheme.surfaceContainerHighest;
    Widget cell(String text, {bool head = false}) => Container(
      constraints: const BoxConstraints(minWidth: 48, maxWidth: 260), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: head ? header : null,
      child: Text(text, style: head ? theme.textTheme.labelMedium : theme.textTheme.bodyMedium));
    final width = rows.first.length;
    return InteractiveViewer(constrained: false, minScale: 0.3, maxScale: 4, boundaryMargin: const EdgeInsets.all(24),
      child: Padding(padding: const EdgeInsets.all(8), child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder(horizontalInside: border, verticalInside: border, top: border, bottom: border, left: border, right: border),
        children: [
          TableRow(children: [cell('', head: true), for (var i = 0; i < width; i++) cell(_column(i), head: true)]),
          for (var r = 0; r < rows.length; r++) TableRow(children: [cell('${r + 1}', head: true), for (final v in rows[r]) cell(v)]),
        ])));
  }
}
