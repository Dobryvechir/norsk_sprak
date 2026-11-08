@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:norsk_audio_groups/screens/dictionaries_screen.dart';
import 'package:norsk_audio_groups/screens/settings_screen.dart';
import 'package:norsk_audio_groups/services/api.dart';
import 'package:norsk_audio_groups/services/dictionaries.dart';
import 'package:path/path.dart' as p;

/// A server with the file `nb` (non-ASCII, so characters and bytes differ); records the requests.
class _Server implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  List<Map<String, Object>> list = [];
  int status = 200;
  final file = utf8.encode('{"å": "ære"}');
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests.add(o);
    final json = {'content-type': ['application/json']};
    if (status != 200) return ResponseBody.fromString('{"detail": "Broken"}', status, headers: json);
    if (o.uri.path.endsWith('/api/dictionaries')) return ResponseBody.fromString(jsonEncode(list), 200, headers: json);
    return ResponseBody.fromBytes(file, 200, headers: json);
  }
  @override void close({bool force = false}) {}
}

/// In memory, so the page can be tested without real files. A download can be held back with [gate].
class _FakeDictionaries extends Dictionaries {
  _FakeDictionaries(this.remote, this.local) : super(Api());
  List<DictionaryInfo> remote;
  final Map<String, int> local;
  Object? listError, downloadError;
  Completer<void>? gate;
  final downloads = <String>[];
  @override Future<List<DictionaryInfo>> available() async { if (listError != null) throw listError!; return remote; }
  @override Future<Map<String, int>> localSizes() async => {...local};
  @override Future<void> download(DictionaryInfo d, void Function(double) onProgress, {CancelToken? cancel}) async {
    downloads.add(d.lang);
    onProgress(0.5);
    await gate?.future;
    if (downloadError != null) throw downloadError!;
    local[d.lang] = d.size;
  }
  @override Future<void> remove(String lang) async { local.remove(lang); }
}

const nb = DictionaryInfo('nb', '/api/dictionary/nb', 15625);
const en = DictionaryInfo('en', '/api/dictionary/en', 2 * 1024 * 1024);

Future<void> showPage(WidgetTester tester, Dictionaries d) async {
  await tester.pumpWidget(MaterialApp(home: DictionariesScreen(dictionaries: d)));
  await tester.pumpAndSettle();
}

Finder button(String text) => find.text(text);

void main() {
  group('Dictionaries service', () {
    late Directory tmp; late _Server server; late Dictionaries dictionaries;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dicts');
      server = _Server();
      final api = Api()..baseUrl = 'https://example.com/app'..token = 'secret';
      api.dio.httpClientAdapter = server;
      dictionaries = Dictionaries(api, root: tmp.path);
    });
    tearDown(() => tmp.delete(recursive: true));

    test('the list is read without the login token; impossible language codes are skipped', () async {
      server.list = [
        {'lang': 'nb', 'url': '/api/dictionary/nb', 'size': 15625},
        {'lang': '../evil', 'url': '/api/dictionary/x', 'size': 1},
      ];
      final list = await dictionaries.available();
      expect(list.map((d) => (d.lang, d.url, d.size)), [('nb', '/api/dictionary/nb', 15625)]);
      expect(server.requests.single.uri.toString(), 'https://example.com/app/api/dictionaries');
      expect(server.requests.single.headers.containsKey('Authorization'), isFalse);
    });

    test('a download is saved byte for byte, so its size equals the server\'s, and can be removed', () async {
      final d = DictionaryInfo('nb', '/api/dictionary/nb', server.file.length);
      final seen = <double>[];
      await dictionaries.download(d, seen.add);

      final file = File(p.join(tmp.path, 'dictionaries', 'dict_nb.json'));
      expect(await file.readAsBytes(), server.file);
      expect(await dictionaries.localSizes(), {'nb': server.file.length});
      expect(DictionaryStatus.merge([d], await dictionaries.localSizes()).single.needsUpdate, isFalse);
      expect(seen.last, 1);
      expect(server.requests.single.uri.toString(), 'https://example.com/app/api/dictionary/nb');
      expect(server.requests.single.headers.containsKey('Authorization'), isFalse);

      await dictionaries.remove('nb');
      expect(await dictionaries.localSizes(), isEmpty);
      await dictionaries.remove('nb'); // nothing there: no error
    });

    test('a failed update keeps the copy already saved and leaves no partial file', () async {
      await dictionaries.download(nb, (_) {});
      final saved = await dictionaries.localSizes();
      server.status = 500;
      await expectLater(dictionaries.download(nb, (_) {}), throwsA(isA<DioException>()));
      expect(await dictionaries.localSizes(), saved);
      final names = Directory(p.join(tmp.path, 'dictionaries')).listSync().map((e) => p.basename(e.path));
      expect(names, ['dict_nb.json']);
    });

    test('other files in the folder are not dictionaries', () async {
      final dir = await Directory(p.join(tmp.path, 'dictionaries')).create(recursive: true);
      for (final name in ['dict_nb.json.partial', 'notes.json', 'dict_.json']) { await File(p.join(dir.path, name)).writeAsString('{}'); }
      expect(await dictionaries.localSizes(), isEmpty);
    });
  });

  test('status: Update only when both sides exist and sizes differ', () {
    final rows = DictionaryStatus.merge([nb, en], {'en': en.size, 'nb': 1, 'uk': 7});
    expect(rows.map((r) => (r.lang, r.downloaded, r.needsUpdate, r.size)), [
      ('en', true, false, en.size), ('nb', true, true, nb.size), ('uk', true, false, 7),
    ]);
    expect(DictionaryStatus.merge([nb], {}).single.downloaded, isFalse);
  });

  testWidgets('Settings has a Manage dictionaries button that opens the Dictionaries page', (tester) async {
    final api = Api()..baseUrl = 'https://example.com';
    api.dio.httpClientAdapter = _Server();
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(api: api)));
    await tester.scrollUntilVisible(button('Manage dictionaries'), 200);
    await tester.ensureVisible(button('Manage dictionaries'));
    await tester.pumpAndSettle();
    await tester.tap(button('Manage dictionaries'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // the page transition; its loading spinner never settles here
    expect(find.byType(DictionariesScreen), findsOneWidget);
    expect(find.text('Dictionaries'), findsOneWidget);
  });

  group('Dictionaries page', () {
    testWidgets('shows language and size in KB or MB; Download saves and turns into Remove', (tester) async {
      final d = _FakeDictionaries([en, nb], {});
      await showPage(tester, d);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('2.0 MB'), findsOneWidget);
      expect(find.text('Norsk'), findsOneWidget);
      expect(find.text('15 KB'), findsOneWidget);
      expect(button('Download'), findsNWidgets(2));
      expect(button('Remove'), findsNothing);
      expect(button('Update'), findsNothing);
      expect(button('Update all'), findsNothing);

      await tester.tap(button('Download').first);
      await tester.pumpAndSettle();
      expect(d.downloads, ['en']);
      expect(button('Download'), findsOneWidget);
      expect(button('Remove'), findsOneWidget);
      expect(button('Update'), findsNothing);
    });

    testWidgets('Remove brings Download back', (tester) async {
      final d = _FakeDictionaries([nb], {'nb': nb.size});
      await showPage(tester, d);
      await tester.tap(button('Remove'));
      await tester.pumpAndSettle();
      expect(d.local, isEmpty);
      expect(button('Download'), findsOneWidget);
    });

    testWidgets('a different size offers Update and Update all, for those files only', (tester) async {
      final d = _FakeDictionaries([en, nb, const DictionaryInfo('uk', '/api/dictionary/uk', 9)], {'en': 1, 'nb': 2})
        ..remote.add(const DictionaryInfo('de', '/api/dictionary/de', 5));
      d.local['de'] = 5;
      await showPage(tester, d);
      expect(button('Update'), findsNWidgets(2));
      expect(button('Remove'), findsNWidgets(3));
      expect(button('Download'), findsOneWidget);
      expect(tester.getTopLeft(button('Update all')).dy, lessThan(tester.getTopLeft(find.text('Deutsch')).dy));

      await tester.tap(button('Update all'));
      await tester.pumpAndSettle();
      expect(d.downloads, ['en', 'nb']);
      expect(button('Update all'), findsNothing);
      expect(button('Update'), findsNothing);
    });

    testWidgets('one Update updates only that file; the row shows progress meanwhile', (tester) async {
      final d = _FakeDictionaries([en, nb], {'en': 1, 'nb': 2})..gate = Completer();
      await showPage(tester, d);
      await tester.tap(button('Update').first);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(button('Update'), findsOneWidget);
      d.gate!.complete();
      await tester.pumpAndSettle();
      expect(d.downloads, ['en']);
      expect(button('Update'), findsOneWidget);
      expect(button('Update all'), findsOneWidget);
    });

    testWidgets('a failed Update all carries on with the rest and reports the error', (tester) async {
      final d = _FakeDictionaries([en, nb], {'en': 1, 'nb': 2})..downloadError = const FormatException('Broken');
      await showPage(tester, d);
      await tester.tap(button('Update all'));
      await tester.pumpAndSettle();
      expect(d.downloads, ['en', 'nb']);
      expect(find.text('Broken'), findsOneWidget);
      expect(button('Update'), findsNWidgets(2));
    });

    testWidgets('without a connection the saved ones can still be removed', (tester) async {
      final d = _FakeDictionaries([], {'nb': 2048})..listError = const FormatException('No connection');
      await showPage(tester, d);
      expect(find.text('No connection'), findsOneWidget);
      expect(find.text('2.0 KB'), findsOneWidget);
      expect(button('Remove'), findsOneWidget);
      expect(button('Download'), findsNothing);
      expect(button('Update'), findsNothing);
    });

    testWidgets('nothing offered and nothing saved says so', (tester) async {
      await showPage(tester, _FakeDictionaries([], {}));
      expect(find.text('No dictionaries available.'), findsOneWidget);
    });
  });
}
