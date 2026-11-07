import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// One worksheet of an .xlsx file: its name and its cells as text, row by row. Rows are padded to
/// the same width; empty rows and columns at the end are left out.
class XlsxSheet {
  final String name;
  final List<List<String>> rows;
  const XlsxSheet(this.name, this.rows);
}

/// Reads the cell values of every worksheet in an .xlsx file (an Office Open XML zip), in workbook
/// order. Numbers are shown as stored (dates appear as their serial numbers); formulas show their last
/// computed value. Throws [FormatException] when [bytes] is not an .xlsx file.
List<XlsxSheet> readXlsx(List<int> bytes) {
  final Archive zip;
  try { zip = ZipDecoder().decodeBytes(bytes); } catch (_) { throw const FormatException('Not an .xlsx file'); }
  XmlDocument? part(String path) {
    final f = zip.findFile(path);
    return f == null ? null : XmlDocument.parse(utf8.decode(f.content, allowMalformed: true));
  }
  final workbook = part('xl/workbook.xml') ?? (throw const FormatException('Not an .xlsx file'));

  // Shared strings: <si> is either <t> or rich text runs <r><t>.
  final shared = [
    for (final si in part('xl/sharedStrings.xml')?.findAllElements('si') ?? const <XmlElement>[])
      si.findAllElements('t').map((t) => t.innerText).join(),
  ];

  // Sheet name → part, through the workbook's relationships.
  final targets = <String, String>{
    for (final r in part('xl/_rels/workbook.xml.rels')?.findAllElements('Relationship') ?? const <XmlElement>[])
      r.getAttribute('Id') ?? '': r.getAttribute('Target') ?? '',
  };
  final result = <XlsxSheet>[];
  for (final sheet in workbook.findAllElements('sheet')) {
    final name = sheet.getAttribute('name') ?? '';
    final rid = sheet.attributes.where((a) => a.name.local == 'id').firstOrNull?.value;
    var target = targets[rid] ?? '';
    if (target.isEmpty) continue;
    target = target.startsWith('/') ? target.substring(1) : p.posix.normalize(p.posix.join('xl', target));
    final doc = part(target);
    if (doc == null) continue;
    result.add(XlsxSheet(name, _cells(doc, shared)));
  }
  return result;
}

List<List<String>> _cells(XmlDocument doc, List<String> shared) {
  final byRow = <int, Map<int, String>>{};
  var nextRow = 0;
  for (final row in doc.findAllElements('row')) {
    final r = (int.tryParse(row.getAttribute('r') ?? '') ?? nextRow + 1) - 1;
    nextRow = r + 1;
    var nextCol = 0;
    for (final c in row.findElements('c')) {
      final col = _column(c.getAttribute('r')) ?? nextCol;
      nextCol = col + 1;
      final text = _value(c, shared);
      if (text.isNotEmpty) (byRow[r] ??= {})[col] = text;
    }
  }
  if (byRow.isEmpty) return [];
  final height = byRow.keys.reduce((a, b) => a > b ? a : b) + 1;
  final width = byRow.values.expand((m) => m.keys).reduce((a, b) => a > b ? a : b) + 1;
  return [for (var r = 0; r < height; r++) [for (var c = 0; c < width; c++) byRow[r]?[c] ?? '']];
}

/// The 0-based column of a cell reference such as "AB12".
int? _column(String? ref) {
  if (ref == null) return null;
  var col = 0, letters = 0;
  for (final unit in ref.toUpperCase().codeUnits) {
    if (unit < 65 || unit > 90) break;
    col = col * 26 + unit - 64; letters++;
  }
  return letters == 0 ? null : col - 1;
}

String _value(XmlElement c, List<String> shared) {
  final type = c.getAttribute('t');
  if (type == 'inlineStr') return c.findAllElements('t').map((t) => t.innerText).join();
  final v = c.getElement('v')?.innerText ?? '';
  switch (type) {
    case 's': final i = int.tryParse(v); return i != null && i >= 0 && i < shared.length ? shared[i] : '';
    case 'b': return v == '1' ? 'TRUE' : v == '0' ? 'FALSE' : v;
    case 'str' || 'e': return v;
  }
  // A number: whole numbers without ".0".
  final n = double.tryParse(v);
  if (n == null) return v;
  return n == n.roundToDouble() && n.abs() < 1e15 ? n.toInt().toString() : v;
}

