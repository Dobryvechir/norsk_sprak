import 'dart:async';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import '../l10n/l10n.dart';
import '../services/google_drive.dart';
import '../services/media_store.dart';
import 'media_save_dialog.dart';

/// Records audio from the microphone: record, pause/resume, stop, with the time and a level meter.
/// The recording is kept temporarily on this device and then offered for saving to Google Drive
/// (see [showMediaSaveDialog]), or handed to [onCaptured] when given (which must delete it when done);
/// either way the screen then closes.
class AudioRecordScreen extends StatefulWidget {
  final GoogleDrive? drive;
  final Future<void> Function(BuildContext context, LocalMedia media, Duration? duration)? onCaptured;
  const AudioRecordScreen({super.key, this.drive, this.onCaptured}) : assert(drive != null || onCaptured != null);
  @override State<AudioRecordScreen> createState() => _AudioRecordScreenState();
}

class _AudioRecordScreenState extends State<AudioRecordScreen> {
  final recorder = AudioRecorder();
  RecordState state = RecordState.stop;
  StreamSubscription<RecordState>? stateSub;
  StreamSubscription<Amplitude>? levelSub;
  /// Microphone level, 0–1.
  double level = 0;
  Duration elapsed = Duration.zero;
  Timer? timer;
  bool busy = false;
  String? error;
  String mimeType = 'audio/mp4';

  bool get recording => state != RecordState.stop;

  @override void initState() {
    super.initState();
    stateSub = recorder.onStateChanged().listen((s) { if (mounted) setState(() => state = s); });
    levelSub = recorder.onAmplitudeChanged(const Duration(milliseconds: 150)).listen((a) {
      // dBFS: about -60 (silence) to 0 (loudest).
      if (mounted) setState(() => level = ((a.current + 60) / 60).clamp(0.0, 1.0));
    });
  }

  @override void dispose() {
    timer?.cancel(); stateSub?.cancel(); levelSub?.cancel();
    recorder.cancel().catchError((_) {}).whenComplete(recorder.dispose);
    super.dispose();
  }

  /// AAC (.m4a) where supported, else Opus (browsers without AAC recording), else WAV.
  Future<(AudioEncoder, String, String)> encoder() async {
    for (final (enc, ext, type) in [
      (AudioEncoder.aacLc, '.m4a', 'audio/mp4'), (AudioEncoder.opus, '.webm', 'audio/webm'), (AudioEncoder.wav, '.wav', 'audio/wav')]) {
      if (await recorder.isEncoderSupported(enc)) return (enc, ext, type);
    }
    return (AudioEncoder.aacLc, '.m4a', 'audio/mp4');
  }

  Future<void> start() async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      if (!await recorder.hasPermission()) { setState(() => error = context.tr('microphonePermissionDenied')); return; }
      final (enc, ext, type) = await encoder();
      mimeType = type;
      final path = kIsWeb ? 'recording$ext' : await MediaTemp.newPath(ext);
      await recorder.start(RecordConfig(encoder: enc), path: path);
      elapsed = Duration.zero;
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && state == RecordState.record) setState(() => elapsed += const Duration(seconds: 1));
      });
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> pauseResume() async {
    try { state == RecordState.pause ? await recorder.resume() : await recorder.pause(); }
    catch (e) { setState(() => error = '$e'); }
  }

  Future<void> stop() async {
    if (!recording || busy) return;
    setState(() => busy = true);
    timer?.cancel();
    try {
      final path = await recorder.stop();
      if (path == null) throw StateError(trNow('recordingFailed'));
      final media = await MediaTemp.adopt(XFile(path, mimeType: mimeType), MediaKind.audio, mimeType: mimeType);
      if (!mounted) { await media.delete(); return; }
      final onCaptured = widget.onCaptured;
      onCaptured != null ? await onCaptured(context, media, elapsed)
        : await showMediaSaveDialog(context, widget.drive!, media, duration: elapsed);
      await media.delete(); // in case it wasn't
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() { error = '$e'; busy = false; });
    }
  }

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paused = state == RecordState.pause;
    return PopScope(canPop: !busy, child: Scaffold(
      appBar: AppBar(title: Text(context.tr('mediaNewAudio')),
        leading: IconButton(tooltip: context.tr('close'), icon: const Icon(Icons.close), onPressed: busy ? null : () => Navigator.pop(context))),
      body: SafeArea(child: Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.mic, size: 96, color: recording && !paused ? Colors.red : theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(formatDuration(elapsed), style: theme.textTheme.displaySmall),
        const SizedBox(height: 16),
        SizedBox(width: 240, child: LinearProgressIndicator(value: recording && !paused ? level : 0, minHeight: 8,
          borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 8),
        Text(context.tr(!recording ? 'tapToRecord' : paused ? 'recordingPaused' : 'recordingNow')),
        const SizedBox(height: 32),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (recording) IconButton.filledTonal(tooltip: context.tr(paused ? 'resume' : 'pause'), iconSize: 36,
            onPressed: busy ? null : pauseResume, icon: Icon(paused ? Icons.play_arrow : Icons.pause)),
          const SizedBox(width: 24),
          busy ? const SizedBox(width: 88, height: 88, child: Center(child: CircularProgressIndicator()))
            : IconButton(tooltip: context.tr(recording ? 'stopRecording' : 'startRecording'), iconSize: 80,
                onPressed: recording ? stop : start,
                icon: Icon(recording ? Icons.stop_circle : Icons.fiber_manual_record, color: recording ? theme.colorScheme.primary : Colors.red)),
          if (recording) const SizedBox(width: 84),
        ]),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 24),
          child: Text(error!, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error))),
      ]))))));
  }
}
