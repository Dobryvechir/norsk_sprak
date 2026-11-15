import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/drive_auth.dart';
import '../services/drive_import.dart';
import '../services/google_drive.dart';
import '../services/media_store.dart';
import '../services/recording_texts.dart';
import '../services/settings.dart';
import 'drive_picker_screen.dart';
import 'media_list_screen.dart';

/// Where a recording's texts and timings come from.
enum TextsSource { manual, ai }

/// Creates a recording in [group], or, when [recording] is given, adds (or replaces) its audio in one
/// more language. Nothing is uploaded: the audio is an audio or video file the user saved through Media
/// on their Google Drive, which is shared with anyone with the link so the group can play it. The texts
/// and timings come from a file the user made (JSON, SRT or WebVTT), or from our AI transcription when
/// the group allows it and the user's limits aren't reached.
class RecordingMediaScreen extends StatefulWidget {
  final Api api; final StudyGroup group; final Recording? recording;
  const RecordingMediaScreen({super.key, required this.api, required this.group, this.recording});
  @override State<RecordingMediaScreen> createState() => _RecordingMediaScreenState();
}

class _RecordingMediaScreenState extends State<RecordingMediaScreen> {
  final drive = GoogleDrive();
  final name = TextEditingController();
  /// The language spoken in the media.
  late String language;
  RecordingMedia? media;
  /// Null until known (or when it couldn't be fetched: the server still decides on saving).
  AiAllowance? allowance;
  bool allowanceLoaded = false;
  TextsSource source = TextsSource.manual;
  /// The chosen texts file: its name and content (read again when [language] changes).
  String? textsName, textsContent;
  RecordingTexts? texts;
  String? textsError;
  bool busy = false;

  bool get aiAllowed => allowance?.enabled ?? allowanceLoaded;

  @override void initState() {
    super.initState();
    // The preferred audio language, unless the recording already has it: then the first one it lacks.
    final existing = widget.recording?.audio.keys.toSet() ?? const <String>{};
    final preferred = AppSettings.instance.audioLanguage;
    language = !existing.contains(preferred) ? preferred
      : languageNames.keys.firstWhere((c) => !existing.contains(c), orElse: () => preferred);
    _loadAllowance();
  }

  @override void dispose() { name.dispose(); super.dispose(); }

  Future<void> _loadAllowance() async {
    AiAllowance? result;
    try { result = await widget.api.aiAllowance(widget.group.id); } catch (_) {}
    if (!mounted) return;
    setState(() {
      allowance = result; allowanceLoaded = true;
      if (aiAllowed && texts == null) source = TextsSource.ai;
    });
  }

  void showError(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is DriveException ? e.message : readableError(e))));
  }

  Future<void> chooseMedia(MediaKind kind) async {
    if (!DriveAuth.instance.configured) { showError(trNow('driveNotConfigured')); return; }
    final file = await Navigator.push<DriveFile>(context, MaterialPageRoute(builder: (_) => MediaListScreen(
      drive: drive, kind: kind, picking: true, pickLabel: 'mediaChoose', pickIcon: Icons.check_circle_outline)));
    if (file == null || !mounted) return;
    setState(() {
      media = RecordingMedia(file.id, file.name, kind == MediaKind.video ? 'video' : 'audio', file.mimeType.isEmpty ? null : file.mimeType);
      if (name.text.trim().isEmpty) name.text = file.name;
    });
  }

  void _readTexts() {
    final fileName = textsName, content = textsContent;
    if (fileName == null || content == null) return;
    try { texts = parseRecordingTexts(fileName, content, language); textsError = null; }
    on RecordingTextsException catch (e) { texts = null; textsError = e.message; }
  }

  void _useTextsFile(String fileName, List<int> bytes) => setState(() {
    textsName = fileName; textsContent = utf8.decode(bytes, allowMalformed: true);
    source = TextsSource.manual;
    _readTexts();
  });

  Future<void> chooseTextsFile() async {
    // On Android, custom extensions become MIME types that often don't match what providers report,
    // so there any file may be picked and the extension is checked when reading it.
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final result = await FilePicker.platform.pickFiles(withData: true, type: android ? FileType.any : FileType.custom,
      allowedExtensions: android ? null : [for (final e in recordingTextsExtensions) e.substring(1)]);
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;
    _useTextsFile(file.name, file.bytes!);
  }

  Future<void> chooseTextsFromDrive() async {
    final chosen = await pickFromDrive(context, const ImportTarget(recordingTextsExtensions), drive: drive);
    if (chosen.isEmpty || !mounted) return;
    setState(() => busy = true);
    try {
      final pick = chosen.single;
      final file = await DriveImporter(drive).fetch(pick.file, pick.plan);
      _useTextsFile(file.name, file.bytes);
    } catch (e) { showError(e); }
    finally { if (mounted) setState(() => busy = false); }
  }

  bool get canSave => !busy && media != null && (widget.recording != null || name.text.trim().isNotEmpty)
    && (source == TextsSource.ai ? aiAllowed : texts != null);

  Future<void> save() async {
    final chosen = media, recording = widget.recording;
    if (!canSave || chosen == null) return;
    final ownTexts = source == TextsSource.manual ? texts : null;
    setState(() => busy = true);
    try {
      // The group's members (and our server) read the file through its link.
      await drive.shareWithAnyone(chosen.driveId);
      if (recording == null) { await widget.api.createRecording(widget.group.id, name.text.trim(), language, chosen, ownTexts); }
      else { await widget.api.setRecordingAudio(recording.id, language, chosen, ownTexts); }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr(ownTexts == null ? 'recordingSavedAi' : 'recordingSaved'))));
      Navigator.pop(context, true);
    } catch (e) { showError(e); }
    finally { if (mounted) setState(() => busy = false); }
  }

  /// Why AI can't be used, or what is left of the allowance.
  String aiInfo(BuildContext context) {
    final a = allowance;
    if (!allowanceLoaded) return context.tr('textsAiHint');
    if (a == null) return context.tr('textsAiHint');
    if (!a.enabled) {
      return context.tr(switch (a.reason) { 'disabled' => 'aiDisabled', 'group_minutes' => 'aiGroupQuotaReached', _ => 'aiQuotaReached' });
    }
    return [
      context.tr('textsAiHint'),
      if (a.remainingMinutes != null) context.tr('aiRemainingMinutes', {'minutes': a.remainingMinutes!.toStringAsFixed(0)}),
      if (a.remainingRecordings != null) context.tr('aiRemainingRecordings', {'count': a.remainingRecordings}),
      if (a.maxDurationMinutes != null) context.tr('aiMaxDuration', {'minutes': a.maxDurationMinutes}),
    ].join(' · ');
  }

  /// For an existing recording: whether its texts in languages the file lacks would stop matching.
  bool get countDiffers {
    final r = widget.recording, t = texts;
    if (r == null || t == null || r.sentenceCount == 0 || r.sentenceCount == t.count) return false;
    return r.sentences.entries.any((e) => !t.sentences.containsKey(e.key) && e.value.any((s) => s.isNotEmpty));
  }

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = widget.recording;
    final chosen = media, t = texts;
    Widget heading(String key) => Padding(padding: const EdgeInsets.only(top: 22, bottom: 8),
      child: Text(context.tr(key), style: theme.textTheme.titleMedium));
    return Scaffold(appBar: AppBar(title: Text(context.tr(recording == null ? 'newRecording' : 'addAudioLanguage'))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: ListView(padding: const EdgeInsets.all(20), children: [
        Text(context.tr('groupLabel', {'name': widget.group.name}), style: theme.textTheme.titleMedium),
        if (recording != null) Text(recording.name, style: theme.textTheme.titleLarge),
        const SizedBox(height: 20),
        if (recording == null) ...[
          TextField(controller: name, enabled: !busy, onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: context.tr('recordingName'), border: const OutlineInputBorder())),
          const SizedBox(height: 18),
        ],
        InputDecorator(decoration: InputDecoration(labelText: context.tr('originalLanguage'), border: const OutlineInputBorder()),
          child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: language, isExpanded: true, isDense: true,
            items: [for (final e in languageNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: busy ? null : (v) { if (v != null) setState(() { language = v; _readTexts(); }); }))),
        if (recording?.audio.containsKey(language) == true) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(context.tr('replacesMedia'), style: TextStyle(color: theme.colorScheme.error))),

        heading('recordingMedia'),
        Text(context.tr('recordingMediaHint'), style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        if (chosen != null) Card(child: ListTile(
          leading: Icon(chosen.kind == 'video' ? Icons.videocam : Icons.mic),
          title: Text(chosen.name), subtitle: Text(context.tr(chosen.kind == 'video' ? 'mediaVideos' : 'mediaAudio')))),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: busy ? null : () => chooseMedia(MediaKind.audio),
            icon: const Icon(Icons.library_music), label: Text(context.tr('chooseMediaAudio'))),
          OutlinedButton.icon(onPressed: busy ? null : () => chooseMedia(MediaKind.video),
            icon: const Icon(Icons.video_library), label: Text(context.tr('chooseMediaVideo'))),
        ]),

        heading('textsSource'),
        RadioGroup<TextsSource>(groupValue: source, onChanged: (v) { if (v != null && !busy) setState(() => source = v); },
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        RadioListTile<TextsSource>(value: TextsSource.manual, contentPadding: EdgeInsets.zero, enabled: !busy,
          title: Text(context.tr('textsManual')), subtitle: Text(context.tr('textsManualHint'))),
        if (source == TextsSource.manual) Padding(padding: const EdgeInsets.only(left: 16, bottom: 8), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: double.infinity, padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
              child: const SelectableText('[\n  {"nb": "Hei.", "en": "Hi.", "timeMs": 0},\n  {"nb": "God dag.", "en": "Good day.", "timeMs": 1450, "endMs": 2750}\n]',
                style: TextStyle(fontFamily: 'monospace', fontSize: 12))),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: busy ? null : chooseTextsFile, icon: const Icon(Icons.description), label: Text(context.tr('chooseTextsFile'))),
              if (DriveAuth.instance.configured) OutlinedButton.icon(onPressed: busy ? null : chooseTextsFromDrive,
                icon: const Icon(Icons.add_to_drive), label: Text(context.tr('driveChooseFrom'))),
            ]),
            if (textsName != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(textsName!, style: theme.textTheme.bodyMedium)),
            if (t != null) Text(context.tr('textsSummary', {'count': t.count,
              'languages': [for (final l in t.sentences.keys) languageNames[l] ?? l].join(', ')})),
            if (textsError != null) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text(textsError!, style: TextStyle(color: theme.colorScheme.error))),
            if (countDiffers) Padding(padding: const EdgeInsets.only(top: 4), child: Text(
              context.tr('textsCountDiffers', {'existing': recording!.sentenceCount, 'count': t!.count}),
              style: TextStyle(color: theme.colorScheme.error))),
          ])),
        RadioListTile<TextsSource>(value: TextsSource.ai, contentPadding: EdgeInsets.zero, enabled: !busy && aiAllowed,
          title: Text(context.tr('textsAi')), subtitle: Text(aiInfo(context),
            style: allowance?.enabled == false ? TextStyle(color: theme.colorScheme.error) : null)),
        ])),

        const SizedBox(height: 20),
        if (busy) const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator()),
        FilledButton.icon(onPressed: canSave ? save : null, icon: const Icon(Icons.save), label: Text(context.tr('saveRecording'))),
      ]))));
  }
}
