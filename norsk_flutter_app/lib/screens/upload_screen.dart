import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/drive_auth.dart';
import '../services/drive_import.dart';
import '../services/google_drive.dart';
import '../services/settings.dart';
import 'drive_picker_screen.dart';
final _audioExtensions = [for (final e in ImportTarget.audio.extensions!) e.substring(1)];
/// Uploads a new recording to [group], or, when [recording] is given, the audio of one more language for it.
class UploadScreen extends StatefulWidget {
  final Api api; final StudyGroup group; final Recording? recording;
  const UploadScreen({super.key, required this.api, required this.group, this.recording});
  @override State<UploadScreen> createState() => _UploadScreenState();
}
class _UploadScreenState extends State<UploadScreen> {
  final name = TextEditingController();
  late String language;
  String? filePath; bool busy = false; double progress = 0;
  /// A file downloaded from Google Drive into the temporary folder, deleted when no longer needed.
  String? _downloaded;
  /// Downloading from Google Drive (with [progress]).
  bool fetching = false;
  @override void initState() {
    super.initState();
    // The preferred audio language, unless the recording already has it: then the first one it lacks.
    final existing = widget.recording?.audio.keys.toSet() ?? const <String>{};
    final preferred = AppSettings.instance.audioLanguage;
    language = !existing.contains(preferred) ? preferred
      : languageNames.keys.firstWhere((c) => !existing.contains(c), orElse: () => preferred);
  }
  @override void dispose() { _forgetDownload(); name.dispose(); super.dispose(); }
  void _forgetDownload() {
    final path = _downloaded; _downloaded = null;
    if (path != null) File(path).parent.delete(recursive: true).ignore();
  }
  /// Downloads an audio file chosen on Google Drive (with the extension its type calls for).
  Future<void> pickFromDriveFile() async {
    final chosen = await pickFromDrive(context, ImportTarget.audio);
    if (chosen.isEmpty || !mounted) return;
    final pick = chosen.single;
    setState(() { fetching = true; progress = 0; });
    try {
      final dir = await Directory(p.join((await getTemporaryDirectory()).path, 'drive_${DateTime.now().microsecondsSinceEpoch}')).create();
      final path = p.join(dir.path, pick.plan.name);
      await GoogleDrive().downloadToFile(pick.file.id, path, onProgress: (got, total) {
        if (total > 0 && mounted) setState(() => progress = got / total);
      });
      _forgetDownload();
      _downloaded = path;
      if (mounted) setState(() { filePath = path; if (name.text.isEmpty) name.text = p.withoutExtension(pick.plan.name); });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is DriveException ? e.message : readableError(e))));
    } finally { if (mounted) setState(() { fetching = false; progress = 0; }); }
  }
  Future<void> pick() async {
    // On Android, FileType.custom turns extensions into MIME types, and those often don't match what
    // Google Drive and other providers report (e.g. m4a), so their files appear disabled.
    // There we let the user pick any file and check the extension ourselves.
    final result = Platform.isAndroid
        ? await FilePicker.platform.pickFiles(type: FileType.any)
        : await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: _audioExtensions);
    if (result == null || result.files.single.path == null) return;
    final ext = result.files.single.name.split('.').last.toLowerCase();
    if (!_audioExtensions.contains(ext)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(context.tr('unsupportedFileType', {'types': _audioExtensions.join(', ')}))));
      }
      return;
    }
    _forgetDownload();
    setState(() { filePath = result.files.single.path; if (name.text.isEmpty) name.text = result.files.single.name.replaceFirst(RegExp(r'\.[^.]+$'), ''); });
  }
  Future<void> upload() async {
    final recording = widget.recording;
    if (filePath == null || (recording == null && name.text.trim().isEmpty)) return;
    setState(() { busy = true; progress = 0; });
    void onProgress(double p) { if (mounted) setState(() => progress = p); }
    try {
      if (recording == null) { await widget.api.upload(widget.group.id, name.text.trim(), language, filePath!, onProgress); }
      else { await widget.api.uploadAudio(recording.id, language, filePath!, onProgress); }
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr('uploadedInfo')))); Navigator.pop(context, true); }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) {
    final recording = widget.recording;
    return Scaffold(appBar: AppBar(title: Text(context.tr(recording == null ? 'uploadRecording' : 'addAudioLanguage'))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text(context.tr('groupLabel', {'name': widget.group.name}), style: Theme.of(context).textTheme.titleMedium),
        if (recording != null) Text(recording.name, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),
        if (recording == null) ...[
          TextField(controller: name, decoration: InputDecoration(labelText: context.tr('recordingName'), border: const OutlineInputBorder())),
          const SizedBox(height: 18),
        ],
        InputDecorator(decoration: InputDecoration(labelText: context.tr('language'), border: const OutlineInputBorder()),
          child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: language, isExpanded: true, isDense: true,
            items: [for (final e in languageNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: busy ? null : (v) { if (v != null) setState(() => language = v); }))),
        if (recording?.audio.containsKey(language) == true) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(context.tr('replacesAudio'), style: TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 18), OutlinedButton.icon(onPressed: busy || fetching ? null : pick, icon: const Icon(Icons.audio_file), label: Text(context.tr('chooseAudioFile'))),
        if (DriveAuth.instance.configured) Padding(padding: const EdgeInsets.only(top: 8), child: OutlinedButton.icon(
          onPressed: busy || fetching ? null : pickFromDriveFile, icon: const Icon(Icons.add_to_drive), label: Text(context.tr('driveChooseFrom')))),
        if (filePath != null) Padding(padding: const EdgeInsets.all(8), child: Text(filePath == _downloaded ? p.basename(filePath!) : filePath!)),
        if (fetching) ...[Text(context.tr('driveDownloading')), const SizedBox(height: 4)],
        if (busy || fetching) LinearProgressIndicator(value: progress == 0 ? null : progress),
        const SizedBox(height: 20), FilledButton.icon(onPressed: busy || fetching || filePath == null ? null : upload,
          icon: const Icon(Icons.cloud_upload), label: Text(busy ? context.tr('uploadingPercent', {'percent': (progress*100).toStringAsFixed(0)}) : context.tr('upload'))),
        const SizedBox(height: 14), Text(context.tr('uploadNotice')),
      ]));
  }
}
