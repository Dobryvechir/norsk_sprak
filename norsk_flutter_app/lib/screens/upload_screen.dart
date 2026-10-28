import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';
import '../services/api.dart';
import '../services/settings.dart';
const _audioExtensions = ['mp3','m4a','wav','ogg','opus','mp4','aac','flac'];
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
  @override void initState() {
    super.initState();
    // The preferred audio language, unless the recording already has it: then the first one it lacks.
    final existing = widget.recording?.audio.keys.toSet() ?? const <String>{};
    final preferred = AppSettings.instance.audioLanguage;
    language = !existing.contains(preferred) ? preferred
      : languageNames.keys.firstWhere((c) => !existing.contains(c), orElse: () => preferred);
  }
  @override void dispose() { name.dispose(); super.dispose(); }
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
        const SizedBox(height: 18), OutlinedButton.icon(onPressed: busy ? null : pick, icon: const Icon(Icons.audio_file), label: Text(context.tr('chooseAudioFile'))),
        if (filePath != null) Padding(padding: const EdgeInsets.all(8), child: Text(filePath!)),
        if (busy) LinearProgressIndicator(value: progress == 0 ? null : progress),
        const SizedBox(height: 20), FilledButton.icon(onPressed: busy || filePath == null ? null : upload,
          icon: const Icon(Icons.cloud_upload), label: Text(busy ? context.tr('uploadingPercent', {'percent': (progress*100).toStringAsFixed(0)}) : context.tr('upload'))),
        const SizedBox(height: 14), Text(context.tr('uploadNotice')),
      ]));
  }
}
