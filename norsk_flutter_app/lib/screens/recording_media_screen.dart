import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/audio_cache.dart';
import '../services/drive_auth.dart';
import '../services/drive_import.dart';
import '../services/google_drive.dart';
import '../services/media_store.dart';
import '../services/offline_chapters.dart';
import '../services/recording_texts.dart';
import '../services/settings.dart';
import 'drive_picker_screen.dart';
import 'media_list_screen.dart';

/// Where a recording's texts and timings come from.
enum TextsSource { manual, ai }

/// Creates a recording in [group], or, when [recording] is given, adds (or replaces) its audio in one
/// more language. Nothing is uploaded: the audio is an audio or video file the user saved through Media
/// on their Google Drive.
///
/// A new recording starts with that media, then a name and where its texts and timings come from:
/// - a file: LanguageTutor's JSON or ODT export (its link to the audio is ignored), or JSON, SRT or
///   WebVTT. It is then saved only on this device, or shared with the group (within the group's monthly
///   share limit) and saved on this device too;
/// - AI, when the user's role and the group's quotas allow it: the server transcribes the media in the
///   chosen language and translates it into the chosen languages; it is queued, and shared once done.
/// A shared media file is made readable by anyone with the link, so the group (and our server) can play it.
class RecordingMediaScreen extends StatefulWidget {
  final Api api; final StudyGroup group; final Recording? recording;
  const RecordingMediaScreen({super.key, required this.api, required this.group, this.recording});
  @override State<RecordingMediaScreen> createState() => _RecordingMediaScreenState();
}

class _RecordingMediaScreenState extends State<RecordingMediaScreen> {
  final drive = GoogleDrive();
  final name = TextEditingController();
  late final store = OfflineChapters(widget.api, recordings: true);
  /// The language spoken in the media.
  late String language;
  /// AI: the languages to translate into.
  late Set<String> translations;
  RecordingMedia? media;
  /// Null until known (or when it couldn't be fetched: the server still decides on saving).
  AiAllowance? allowance;
  bool allowanceLoaded = false;
  ShareAllowance? shareAllowance;
  TextsSource source = TextsSource.manual;
  /// The chosen texts file: its name and content (read again when [language] changes).
  String? textsName;
  Uint8List? textsBytes;
  RecordingTexts? texts;
  String? textsError;
  bool busy = false;
  /// Progress (0–1) of saving the media on this device, else null.
  double? saving;

  bool get isNew => widget.recording == null;
  bool get aiAllowed => widget.group.mayUseAi && (allowance?.enabled ?? allowanceLoaded);
  /// Unknown (no connection): let the server decide.
  bool get shareAllowed => shareAllowance?.enabled ?? true;

  @override void initState() {
    super.initState();
    // The preferred audio language, unless the recording already has it: then the first one it lacks.
    final existing = widget.recording?.audio.keys.toSet() ?? const <String>{};
    final preferred = AppSettings.instance.audioLanguage;
    language = !existing.contains(preferred) ? preferred
      : languageNames.keys.firstWhere((c) => !existing.contains(c), orElse: () => preferred);
    translations = {...AppSettings.instance.textLanguages}..remove(language);
    if (widget.group.mayUseAi) { _loadAllowance(); } else { allowanceLoaded = true; }
    if (isNew) _loadShareAllowance();
  }

  @override void dispose() { name.dispose(); super.dispose(); }

  Future<void> _loadAllowance() async {
    AiAllowance? result;
    try { result = await widget.api.aiAllowance(widget.group.id); } catch (_) {}
    if (!mounted) return;
    setState(() { allowance = result; allowanceLoaded = true; });
  }

  Future<void> _loadShareAllowance() async {
    ShareAllowance? result;
    try { result = await widget.api.shareAllowance(widget.group.id); } catch (_) {}
    if (mounted) setState(() => shareAllowance = result);
  }

  void showError(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is DriveException ? e.message : readableError(e))));
  }
  void showMessage(String key, [Map<String, Object?> args = const {}]) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr(key, args))));
  }

  Future<void> chooseMedia(MediaKind kind) async {
    if (!DriveAuth.instance.configured) { showError(trNow('driveNotConfigured')); return; }
    final file = await Navigator.push<DriveFile>(context, MaterialPageRoute(builder: (_) => MediaListScreen(
      drive: drive, kind: kind, picking: true, pickLabel: 'mediaChoose', pickIcon: Icons.check_circle_outline)));
    if (file == null || !mounted) return;
    setState(() {
      media = RecordingMedia(file.id, file.name, kind == MediaKind.video ? 'video' : 'audio',
        file.mimeType.isEmpty ? null : file.mimeType, file.size);
      if (name.text.trim().isEmpty) name.text = _withoutExtension(file.name);
    });
  }

  static String _withoutExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  void _readTexts() {
    final fileName = textsName, bytes = textsBytes;
    if (fileName == null || bytes == null) return;
    try {
      texts = parseRecordingTextsBytes(fileName, bytes, language);
      textsError = null;
      // LanguageTutor's files say which language their audio is in.
      final own = texts!.language;
      if (own != null && own != language) { language = own; translations.remove(own); }
    } on RecordingTextsException catch (e) { texts = null; textsError = e.message; }
  }

  void _useTextsFile(String fileName, List<int> bytes) => setState(() {
    textsName = fileName; textsBytes = Uint8List.fromList(bytes);
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

  bool get hasBasics => !busy && media != null && (!isNew || name.text.trim().isNotEmpty);
  bool get canUseFile => hasBasics && source == TextsSource.manual && texts != null;
  bool get canSendToAi => hasBasics && source == TextsSource.ai && aiAllowed;

  /// The media on Google Drive, fetched for saving on this device.
  Future<Recording> _saveLocally(Recording recording, RecordingMedia chosen) => store.saveOwn(recording,
    (v) { if (mounted) setState(() => saving = v); },
    native: (language, path, progress) async {
      await drive.downloadToFile(chosen.driveId, path, onProgress: (received, total) { if (total > 0) progress(received / total); });
      return AudioCache.extensionFor(chosen.mimeType, chosen.name);
    },
    web: (language, progress) async {
      final bytes = await drive.downloadBytes(chosen.driveId, onProgress: (received, total) { if (total > 0) progress(received / total); });
      return (bytes, chosen.mimeType ?? 'audio/mpeg');
    });

  /// "Save only locally": the recording exists only on this device.
  Future<void> saveOnlyLocally() async {
    final chosen = media, t = texts;
    if (!canUseFile || chosen == null || t == null) return;
    setState(() { busy = true; saving = 0; });
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final user = widget.api.user;
      final recording = Recording('local-${DateTime.now().microsecondsSinceEpoch}', widget.group.id, name.text.trim(),
        {language: RecordingAudio('ready', now, 0, null, t.startMs, t.filledEnds(_noEndMs(t)))}, t.sentences, null,
        RecordingInfo(uploaderId: user?.id, author: user?.email.split('@').first, createdAt: now, source: 'local'));
      await _saveLocally(recording, chosen);
      showMessage('recordingSavedLocally');
      if (mounted) Navigator.pop(context, true);
    } catch (e) { showError(e); }
    finally { if (mounted) setState(() { busy = false; saving = null; }); }
  }

  /// The end of a last sentence without one: an hour after its start (playing stops at the end of the media).
  static int _noEndMs(RecordingTexts t) => t.startMs.last + 3600000;

  /// "Share": shared with the group, and saved on this device too.
  Future<void> share() async {
    final chosen = media, t = texts;
    if (!canUseFile || chosen == null || t == null) return;
    setState(() => busy = true);
    String? id;
    try {
      // The group's members (and our server) read the file through its link.
      await drive.shareWithAnyone(chosen.driveId);
      id = await widget.api.createRecording(widget.group.id, name.text.trim(), language, chosen, t);
      setState(() => saving = 0);
      await _saveLocally(await widget.api.recording(id), chosen);
      showMessage('recordingShared');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (id == null) { showError(e); }
      else {
        showMessage('sharedNotSavedLocally', {'error': e is DriveException ? e.message : readableError(e)});
        if (mounted) Navigator.pop(context, true);
      }
    }
    finally { if (mounted) setState(() { busy = false; saving = null; }); }
  }

  /// AI: queued on the server, which shares it once transcribed and translated.
  Future<void> sendToAi() async {
    final chosen = media;
    if (!canSendToAi || chosen == null) return;
    setState(() => busy = true);
    try {
      await drive.shareWithAnyone(chosen.driveId);
      await widget.api.createRecording(widget.group.id, name.text.trim(), language, chosen, null,
        translations: orderedLanguages(translations.where((l) => l != language)));
      showMessage('recordingQueued');
      if (mounted) Navigator.pop(context, true);
    } catch (e) { showError(e); }
    finally { if (mounted) setState(() => busy = false); }
  }

  /// An existing recording: its audio in [language] is added or replaced on the server.
  Future<void> saveLanguage() async {
    final chosen = media, recording = widget.recording;
    final ownTexts = source == TextsSource.manual ? texts : null;
    if (chosen == null || recording == null || !(source == TextsSource.ai ? canSendToAi : canUseFile)) return;
    setState(() => busy = true);
    try {
      await drive.shareWithAnyone(chosen.driveId);
      await widget.api.setRecordingAudio(recording.id, language, chosen, ownTexts);
      showMessage(ownTexts == null ? 'recordingSavedAi' : 'recordingSaved');
      if (mounted) Navigator.pop(context, true);
    } catch (e) { showError(e); }
    finally { if (mounted) setState(() => busy = false); }
  }

  /// Why AI can't be used, or what is left of the allowance.
  String aiInfo(BuildContext context) {
    if (!widget.group.mayUseAi) return context.tr('aiNotForRole');
    final a = allowance;
    if (!allowanceLoaded || a == null) return context.tr('textsAiHint');
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

  /// Why "Share" can't be used, or how many shares are left this month; null when nothing to say.
  String? shareInfo(BuildContext context) {
    final a = shareAllowance;
    if (a == null) return null;
    if (!a.enabled) return context.tr(a.limit == 0 ? 'shareNotAllowed' : 'shareQuotaReached');
    return a.remaining == null ? null : context.tr('shareRemaining', {'count': a.remaining});
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
    final chosen = media;
    Widget heading(String key) => Padding(padding: const EdgeInsets.only(top: 22, bottom: 8),
      child: Text(context.tr(key), style: theme.textTheme.titleMedium));
    return Scaffold(appBar: AppBar(title: Text(context.tr(isNew ? 'newRecording' : 'addAudioLanguage'))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: ListView(padding: const EdgeInsets.all(20), children: [
        Text(context.tr('groupLabel', {'name': widget.group.name}), style: theme.textTheme.titleMedium),
        if (recording != null) Text(recording.name, style: theme.textTheme.titleLarge),

        heading('recordingMedia'),
        Text(context.tr(isNew ? 'recordingMediaFirst' : 'recordingMediaHint'), style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        if (chosen != null) Card(child: ListTile(
          leading: Icon(chosen.kind == 'video' ? Icons.videocam : Icons.mic),
          title: Text(chosen.name), subtitle: Text([context.tr(chosen.kind == 'video' ? 'mediaVideos' : 'mediaAudio'),
            if (chosen.size != null) formatMegabytes(chosen.size!)].join(' · ')))),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: busy ? null : () => chooseMedia(MediaKind.audio),
            icon: const Icon(Icons.library_music), label: Text(context.tr('chooseMediaAudio'))),
          OutlinedButton.icon(onPressed: busy ? null : () => chooseMedia(MediaKind.video),
            icon: const Icon(Icons.video_library), label: Text(context.tr('chooseMediaVideo'))),
        ]),

        if (chosen != null || !isNew) ...[
          if (isNew) ...[
            const SizedBox(height: 22),
            TextField(controller: name, enabled: !busy, onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: context.tr('recordingName'), border: const OutlineInputBorder())),
          ],
          heading('textsSource'),
          RadioGroup<TextsSource>(groupValue: source, onChanged: (v) { if (v != null && !busy) setState(() => source = v); },
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              RadioListTile<TextsSource>(value: TextsSource.manual, contentPadding: EdgeInsets.zero, enabled: !busy,
                title: Text(context.tr('textsFromFile')), subtitle: Text(context.tr('textsFromFileHint'))),
              RadioListTile<TextsSource>(value: TextsSource.ai, contentPadding: EdgeInsets.zero, enabled: !busy && aiAllowed,
                title: Text(context.tr('textsAi')), subtitle: Text(aiInfo(context),
                  style: aiAllowed ? null : TextStyle(color: theme.colorScheme.error))),
            ])),
          const SizedBox(height: 8),
          if (source == TextsSource.manual) ..._fileSection(context) else ..._aiSection(context),
          if (recording?.audio.containsKey(language) == true) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(context.tr('replacesMedia'), style: TextStyle(color: theme.colorScheme.error))),
        ],

        const SizedBox(height: 20),
        if (busy) Padding(padding: const EdgeInsets.only(bottom: 12), child: LinearProgressIndicator(value: saving == 0 ? null : saving)),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: _actions(context)),
      ]))));
  }

  Widget _languageField(BuildContext context, Iterable<String> codes) {
    final items = orderedLanguages({...codes, language});
    return InputDecorator(decoration: InputDecoration(labelText: context.tr('originalLanguage'), border: const OutlineInputBorder()),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: language, isExpanded: true, isDense: true,
        items: [for (final c in items) DropdownMenuItem(value: c, child: Text(languageNames[c] ?? c))],
        onChanged: busy ? null : (v) { if (v != null) setState(() { language = v; translations.remove(v); _readTexts(); }); })));
  }

  List<Widget> _fileSection(BuildContext context) {
    final theme = Theme.of(context);
    final t = texts, recording = widget.recording;
    // LanguageTutor's files say which languages they have; other files may be in any language.
    final fileLanguages = t?.language != null ? t!.sentences.keys : languageNames.keys;
    return [
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
      if (textsName != null || !isNew) ...[const SizedBox(height: 16), _languageField(context, fileLanguages)],
      if (isNew && shareInfo(context) != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(shareInfo(context)!,
        style: shareAllowed ? theme.textTheme.bodySmall : TextStyle(color: theme.colorScheme.error))),
    ];
  }

  List<Widget> _aiSection(BuildContext context) => [
    _languageField(context, languageNames.keys),
    if (isNew) ...[
      Padding(padding: const EdgeInsets.only(top: 16, bottom: 8), child: Text(context.tr('translateInto'), style: Theme.of(context).textTheme.titleSmall)),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final c in languageNames.keys) if (c != language) FilterChip(label: Text(languageNames[c]!), selected: translations.contains(c),
          onSelected: busy ? null : (on) => setState(() => on ? translations.add(c) : translations.remove(c))),
      ]),
    ],
  ];

  List<Widget> _actions(BuildContext context) {
    final cancel = TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: Text(context.tr('cancel')));
    if (!isNew) {
      return [cancel, FilledButton.icon(onPressed: (source == TextsSource.ai ? canSendToAi : canUseFile) ? saveLanguage : null,
        icon: const Icon(Icons.save), label: Text(context.tr('saveRecording')))];
    }
    if (source == TextsSource.ai) {
      return [cancel, FilledButton.icon(onPressed: canSendToAi ? sendToAi : null, icon: const Icon(Icons.auto_awesome), label: Text(context.tr('sendToAi')))];
    }
    return [
      cancel,
      OutlinedButton.icon(onPressed: canUseFile ? saveOnlyLocally : null, icon: const Icon(Icons.phone_android), label: Text(context.tr('saveOnlyLocally'))),
      FilledButton.icon(onPressed: canUseFile && shareAllowed ? share : null, icon: const Icon(Icons.cloud_upload), label: Text(context.tr('share'))),
    ];
  }
}

/// [bytes] as megabytes with one decimal, e.g. "12.3 MB" (at least "0.1 MB").
String formatMegabytes(int bytes) {
  final mb = bytes / (1024 * 1024);
  return '${(mb < 0.1 ? 0.1 : mb).toStringAsFixed(1)} MB';
}
