import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/entities.dart';
import '../services/api.dart';
const _audioExtensions = ['mp3','m4a','wav','ogg','opus','mp4','aac','flac'];
class UploadScreen extends StatefulWidget {
  final Api api; final StudyGroup group;
  const UploadScreen({super.key, required this.api, required this.group});
  @override State<UploadScreen> createState() => _UploadScreenState();
}
class _UploadScreenState extends State<UploadScreen> {
  final name = TextEditingController();
  String? filePath; bool busy = false; double progress = 0;
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
          content: Text('Unsupported file type. Choose one of: ${_audioExtensions.join(', ')}')));
      }
      return;
    }
    setState(() { filePath = result.files.single.path; if (name.text.isEmpty) name.text = result.files.single.name.replaceFirst(RegExp(r'\.[^.]+$'), ''); });
  }
  Future<void> upload() async {
    if (filePath == null || name.text.trim().isEmpty) return;
    setState(() { busy = true; progress = 0; });
    try {
      await widget.api.upload(widget.group.id, name.text.trim(), filePath!, (p) { if (mounted) setState(() => progress = p); });
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Uploaded. Transcription will run on the server.'))); Navigator.pop(context); }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Upload recording')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      Text('Group: ${widget.group.name}', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 20), TextField(controller: name, decoration: const InputDecoration(labelText: 'Recording name', border: OutlineInputBorder())),
      const SizedBox(height: 18), OutlinedButton.icon(onPressed: busy ? null : pick, icon: const Icon(Icons.audio_file), label: const Text('Choose audio file')),
      if (filePath != null) Padding(padding: const EdgeInsets.all(8), child: Text(filePath!)),
      if (busy) LinearProgressIndicator(value: progress == 0 ? null : progress),
      const SizedBox(height: 20), FilledButton.icon(onPressed: busy || filePath == null ? null : upload,
        icon: const Icon(Icons.cloud_upload), label: Text(busy ? 'Uploading ${(progress*100).toStringAsFixed(0)}%' : 'Upload')),
      const SizedBox(height: 14), const Text('Upload permission and quotas are checked by the server. Viewers cannot upload. The maximum upload size is determined by the server configuration.'),
    ]));
}
