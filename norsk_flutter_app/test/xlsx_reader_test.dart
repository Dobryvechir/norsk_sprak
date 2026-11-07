import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/services/xlsx_reader.dart';

List<int> xlsx(Map<String, String> parts) {
  final zip = Archive();
  parts.forEach((path, text) { final b = utf8.encode(text); zip.addFile(ArchiveFile(path, b.length, b)); });
  return ZipEncoder().encode(zip);
}

void main() {
  test('reads shared, inline, number and boolean cells of every sheet in workbook order', () {
    final sheets = readXlsx(xlsx({
      'xl/workbook.xml': '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
        '<sheet name="Ord" sheetId="1" r:id="rId2"/><sheet name="Tom" sheetId="2" r:id="rId1"/></sheets></workbook>',
      'xl/_rels/workbook.xml.rels': '<Relationships><Relationship Id="rId1" Target="worksheets/sheet2.xml"/>'
        '<Relationship Id="rId2" Target="/xl/worksheets/sheet1.xml"/></Relationships>',
      'xl/sharedStrings.xml': '<sst><si><t>hund</t></si><si><r><t>kat</t></r><r><t>t</t></r></si></sst>',
      'xl/worksheets/sheet1.xml': '<worksheet><sheetData>'
        '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1"><v>3</v></c></row>'
        '<row r="3"><c r="B3" t="s"><v>1</v></c><c r="C3"><v>2.5</v></c><c r="D3" t="b"><v>1</v></c>'
        '<c r="E3" t="inlineStr"><is><t>æøå</t></is></c></row></sheetData></worksheet>',
      'xl/worksheets/sheet2.xml': '<worksheet><sheetData/></worksheet>',
    }));
    expect(sheets.map((s) => s.name), ['Ord', 'Tom']);
    expect(sheets.first.rows, [
      ['hund', '', '3', '', ''],
      ['', '', '', '', ''],
      ['', 'katt', '2.5', 'TRUE', 'æøå'],
    ]);
    expect(sheets.last.rows, isEmpty);
  });

  test('a file that is not .xlsx is a FormatException', () {
    expect(() => readXlsx(utf8.encode('%PDF-1.7')), throwsFormatException);
  });
}
