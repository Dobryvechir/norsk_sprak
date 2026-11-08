import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/settings.dart';
import '../services/word_dictionary.dart';

/// The colors of the chosen text languages in word translations, in the order of those languages: all
/// readable on the app's light background, with the most distinct ones first. The word itself is black.
const wordTranslationColors = <Color>[
  Color(0xFF1E7B1E), Color(0xFFC62828), Color(0xFF1565C0), Color(0xFF7B1FA2),
  Color(0xFFB45309), Color(0xFF00796B), Color(0xFFC2185B), Color(0xFF6D4C41),
  Color(0xFF303F9F), Color(0xFF6B7000), Color(0xFF00728F), Color(0xFF9C27B0),
  Color(0xFF616161), Color(0xFF880E4F), Color(0xFF0D3C78), Color(0xFF33691E),
];

/// The chosen text languages to translate words of a [main]-language sentence into, each with its color.
/// A language keeps its color on every word, whichever translations a word happens to have.
Map<String, Color> wordTranslationLanguages(String main) {
  final languages = orderedLanguages(AppSettings.instance.textLanguages).where((l) => l != main).toList();
  return {for (var i = 0; i < languages.length; i++) languages[i]: wordTranslationColors[i % wordTranslationColors.length]};
}

/// The "Word translation" label with the language names in their colors, which explain the line below it.
class WordTranslationHeader extends StatelessWidget {
  final Map<String, Color> languages;
  const WordTranslationHeader({super.key, required this.languages});
  @override Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Wrap(spacing: 10, children: [
      Text(context.tr('wordTranslation'), style: style?.copyWith(color: Theme.of(context).colorScheme.primary)),
      for (final e in languages.entries) Text(languageNames[e.key] ?? e.key, style: style?.copyWith(color: e.value)),
    ]);
  }
}

/// [sentence] with the translations of each word after it in [languages]' colors. A word with an entry
/// is underlined and opens the entry; any other text stays as it is in the sentence.
class WordTranslationLine extends StatefulWidget {
  final String sentence;
  final WordDictionary dictionary;
  final Map<String, Color> languages;
  const WordTranslationLine({super.key, required this.sentence, required this.dictionary, required this.languages});
  @override State<WordTranslationLine> createState() => _WordTranslationLineState();
}
class _WordTranslationLineState extends State<WordTranslationLine> {
  final recognizers = <TapGestureRecognizer>[];
  TextSpan? span;
  String? builtFor;

  @override void dispose() { disposeRecognizers(); super.dispose(); }
  void disposeRecognizers() { for (final r in recognizers) { r.dispose(); } recognizers.clear(); }

  void open(DictionaryEntry entry) => Navigator.push(context, MaterialPageRoute(fullscreenDialog: true,
    builder: (_) => WordEntryScreen(entry: entry, languages: widget.languages)));

  TextSpan buildSpan() {
    disposeRecognizers();
    return TextSpan(children: [
      for (final part in widget.dictionary.analyze(widget.sentence))
        if (part.entry == null) TextSpan(text: part.text) else ...[
          TextSpan(text: part.text, style: const TextStyle(decoration: TextDecoration.underline),
            recognizer: TapGestureRecognizer()..onTap = () => open(part.entry!)),
          for (final e in widget.languages.entries)
            if (part.entry!.tr[e.key]?.isNotEmpty == true) TextSpan(text: ' ${part.entry!.tr[e.key]}', style: TextStyle(color: e.value)),
        ],
    ]);
  }

  void collectRecognizers(InlineSpan root) => root.visitChildren((s) {
    if (s is TextSpan && s.recognizer is TapGestureRecognizer) recognizers.add(s.recognizer! as TapGestureRecognizer);
    return true;
  });

  /// The player rebuilds this often: the spans are kept until they change, because a tap
  /// in progress is lost when its recognizer is replaced.
  TextSpan currentSpan() {
    final key = '${identityHashCode(widget.dictionary)}|${widget.languages.entries.map((e) => '${e.key}=${e.value.toARGB32()}').join(',')}|${widget.sentence}';
    if (key != builtFor || span == null) {
      span = buildSpan();
      collectRecognizers(span!);
      builtFor = key;
    }
    return span!;
  }

  @override Widget build(BuildContext context) => Text.rich(currentSpan(),
    style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.black, height: 1.5));
}

/// Everything the dictionary says about one word, as a page of its own. Translations are
/// shown in the chosen text languages only, in the same colors as in the word translation.
class WordEntryScreen extends StatelessWidget {
  final DictionaryEntry entry;
  final Map<String, Color> languages;
  const WordEntryScreen({super.key, required this.entry, required this.languages});

  /// "Masculine m1" for "nm m1". An unknown gender is shown as it is in the dictionary.
  static String genderText(BuildContext context, String gender) {
    final parts = gender.trim().split(RegExp(r'\s+'));
    final name = switch (parts.first) {
      'nm' => context.tr('genderMasculine'), 'nf' => context.tr('genderFeminine'), 'nn' => context.tr('genderNeuter'), _ => parts.first,
    };
    return [name, ...parts.skip(1)].join(' ');
  }

  /// The name of a grammatical form; an unknown one is shown as it is in the dictionary.
  static String formName(BuildContext context, String form) => switch (form) {
    'Sing-Ind' => context.tr('formSingularIndefinite'), 'Sing-Def' => context.tr('formSingularDefinite'),
    'Plur-Ind' => context.tr('formPluralIndefinite'), 'Plur-Def' => context.tr('formPluralDefinite'),
    '' => context.tr('formOther'), _ => form,
  };

  List<Widget> translations(Map<String, String> tr, {TextStyle? style}) => [
    for (final e in languages.entries)
      if (tr[e.key]?.isNotEmpty == true) Text(tr[e.key]!, style: (style ?? const TextStyle()).copyWith(color: e.value)),
  ];

  Widget textBlock(DictionaryText text) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(text.orig, style: const TextStyle(color: Colors.black)),
    ...translations(text.tr),
  ]));

  /// A numbered meaning: its definition, its labels (shown as the dictionary has them) and, in each
  /// language's color, the translations for this meaning and any note for learners of that language.
  Widget senseBlock(ThemeData theme, int number, DictionarySense sense) {
    final labels = [sense.pos, sense.domain, sense.register].where((label) => label.isNotEmpty).join(' · ');
    return Padding(padding: const EdgeInsets.only(bottom: 14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$number. ${sense.gloss}'.trim(), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600)),
      if (labels.isNotEmpty) Text(labels, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic, color: theme.colorScheme.onSurfaceVariant)),
      for (final e in languages.entries) ...[
        if (sense.tr[e.key]?.isNotEmpty == true) Text(sense.tr[e.key]!.join(', '), style: TextStyle(color: e.value)),
        if (sense.notes[e.key]?.isNotEmpty == true) Text(sense.notes[e.key]!, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic, color: e.value)),
      ],
    ]));
  }

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String key) => Padding(padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(context.tr(key), style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)));
    return Scaffold(appBar: AppBar(title: Text(entry.original)),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: ListView(padding: const EdgeInsets.all(20), children: [
        Text(entry.original, style: theme.textTheme.headlineSmall?.copyWith(color: Colors.black)),
        if (entry.gender.trim().isNotEmpty) Text(genderText(context, entry.gender), style: theme.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
        const SizedBox(height: 8),
        ...translations(entry.tr, style: theme.textTheme.titleMedium),
        if (entry.senses.isNotEmpty) ...[
          heading('wordMeanings'),
          for (var i = 0; i < entry.senses.length; i++) senseBlock(theme, i + 1, entry.senses[i]),
        ],
        if (entry.declination.isNotEmpty) ...[
          heading('wordInflection'),
          for (final e in entry.declination.entries) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text.rich(TextSpan(children: [
            TextSpan(text: '${formName(context, e.key)}: ', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            TextSpan(text: e.value.split(',').map((form) => form.trim()).join(', '), style: const TextStyle(color: Colors.black)),
          ]))),
        ],
        if (entry.description.isNotEmpty) ...[heading('wordDefinitions'), for (final t in entry.description) textBlock(t)],
        if (entry.examples.isNotEmpty) ...[heading('wordExamples'), for (final t in entry.examples) textBlock(t)],
        if (entry.expressions.isNotEmpty) ...[
          heading('wordExpressions'),
          for (final x in entry.expressions) Padding(padding: const EdgeInsets.only(bottom: 14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(x.orig, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600)),
            ...translations(x.tr),
            if (x.description.isNotEmpty) Padding(padding: const EdgeInsetsDirectional.only(start: 16, top: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final t in x.description) textBlock(t)])),
          ])),
        ],
      ]))));
  }
}
