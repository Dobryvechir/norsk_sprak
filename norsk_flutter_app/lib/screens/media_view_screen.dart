import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import '../l10n/l10n.dart';
import '../services/google_drive.dart';
import '../services/media_store.dart';
import '../widgets/full_view.dart';

/// Full screen view of [kind] [name] from Google Drive: a picture (zoomable), a video or an audio
/// player, with a cross at the top left to go back. The file is downloaded into the temporary Media
/// storage (removed when leaving Media), so viewing it again needs no new download.
class MediaViewScreen extends StatefulWidget {
  final GoogleDrive drive; final MediaKind kind; final String name;
  const MediaViewScreen({super.key, required this.drive, required this.kind, required this.name});
  @override State<MediaViewScreen> createState() => _MediaViewScreenState();
}

class _MediaViewScreenState extends State<MediaViewScreen> {
  LocalMedia? media;
  double? progress;
  String? error;

  @override void initState() { super.initState(); load(); }

  Future<void> load() async {
    setState(() { error = null; progress = null; });
    try {
      var m = MediaTemp.viewed(widget.kind, widget.name);
      if (m == null) {
        final file = await widget.drive.findMedia(widget.kind, widget.name);
        if (file == null) throw DriveException(trNow('mediaNotFound', {'name': widget.name}));
        final type = file.mimeType.isEmpty ? widget.kind.defaultMimeType : file.mimeType;
        void onProgress(int got, int total) { if (mounted && total > 0) setState(() => progress = got / total); }
        if (kIsWeb) {
          final bytes = await widget.drive.downloadBytes(file.id, onProgress: onProgress);
          m = await MediaTemp.saveViewed(widget.kind, widget.name, type, bytes: bytes);
        } else {
          final path = await MediaTemp.newPath(extensionFor(type));
          await widget.drive.downloadToFile(file.id, path, onProgress: onProgress);
          m = await MediaTemp.saveViewed(widget.kind, widget.name, type, path: path);
        }
      }
      if (mounted) setState(() => media = m);
    } catch (e) {
      if (mounted) setState(() => error = e is DriveException ? e.message : '$e');
    }
  }

  @override Widget build(BuildContext context) {
    final m = media;
    const white = Colors.white;
    final Widget body = error != null
      ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: white)),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: load, icon: const Icon(Icons.refresh), label: Text(context.tr('refresh'))),
        ])))
      : m == null
        ? Center(child: SizedBox(width: 220, child: Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 12),
            Text(context.tr('downloading'), style: const TextStyle(color: white)),
          ])))
        : switch (widget.kind) {
            MediaKind.picture => _PictureView(media: m),
            MediaKind.video => _VideoView(media: m),
            MediaKind.audio => _AudioView(media: m, name: widget.name),
          };
    return Scaffold(backgroundColor: Colors.black, body: Stack(children: [
      Positioned.fill(child: body),
      SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: IconButton(tooltip: context.tr('close'),
        style: IconButton.styleFrom(backgroundColor: Colors.black45), color: white, iconSize: 28,
        onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)))),
    ]));
  }
}

/// A file extension for [mimeType], so the platform players recognise the downloaded file.
String extensionFor(String mimeType) => switch (mimeType.split(';').first.trim()) {
  'image/jpeg' => '.jpg', 'image/png' => '.png', 'image/heic' => '.heic', 'image/webp' => '.webp',
  'video/mp4' => '.mp4', 'video/quicktime' => '.mov', 'video/webm' => '.webm',
  'audio/mp4' || 'audio/x-m4a' || 'audio/aac' => '.m4a', 'audio/webm' => '.webm', 'audio/ogg' => '.ogg',
  'audio/wav' || 'audio/x-wav' => '.wav', 'audio/mpeg' => '.mp3',
  _ => '',
};

class _PictureView extends StatefulWidget {
  final LocalMedia media;
  const _PictureView({required this.media});
  @override State<_PictureView> createState() => _PictureViewState();
}

class _PictureViewState extends State<_PictureView> {
  late final Future<ImageProvider> image = widget.media.path != null && !kIsWeb
    ? Future.value(FileImage(File(widget.media.path!)))
    : widget.media.readBytes().then<ImageProvider>(MemoryImage.new);

  @override Widget build(BuildContext context) {
    final error = Center(child: Text(context.tr('mediaCannotShow'), style: const TextStyle(color: Colors.white)));
    return FutureBuilder<ImageProvider>(future: image, builder: (_, snap) => snap.hasError ? error
      : !snap.hasData ? const Center(child: CircularProgressIndicator())
      : FullImage(image: snap.data!, error: error));
  }
}

class _VideoView extends StatefulWidget {
  final LocalMedia media;
  const _VideoView({required this.media});
  @override State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
  late final VideoPlayerController controller = widget.media.path != null && !kIsWeb
    ? VideoPlayerController.file(File(widget.media.path!)) : VideoPlayerController.networkUrl(Uri.parse(widget.media.source));
  String? error;

  @override void initState() {
    super.initState();
    controller.addListener(changed);
    controller.initialize().then((_) => controller.play()).catchError((Object e) { if (mounted) setState(() => error = '$e'); });
  }
  @override void dispose() { controller.removeListener(changed); controller.dispose(); super.dispose(); }
  void changed() { if (mounted) setState(() {}); }
  void playPause() => controller.value.isPlaying ? controller.pause() : controller.play();

  @override Widget build(BuildContext context) {
    const white = Colors.white;
    final v = controller.value;
    if (error != null || v.hasError) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(
        '${context.tr('mediaCannotShow')}\n${error ?? v.errorDescription ?? ''}', textAlign: TextAlign.center, style: const TextStyle(color: white))));
    }
    if (!v.isInitialized) return const Center(child: CircularProgressIndicator());
    return Column(children: [
      Expanded(child: GestureDetector(onTap: playPause, child: FullView(aspectRatio: v.aspectRatio, child: VideoPlayer(controller)))),
      SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(8, 0, 16, 8), child: Row(children: [
        IconButton(tooltip: context.tr('play'), color: white, iconSize: 36, onPressed: playPause,
          icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow)),
        Expanded(child: VideoProgressIndicator(controller, allowScrubbing: true, padding: const EdgeInsets.symmetric(vertical: 12))),
        const SizedBox(width: 12),
        Text('${formatDuration(v.position)} / ${formatDuration(v.duration)}', style: const TextStyle(color: white)),
      ]))),
    ]);
  }
}

class _AudioView extends StatefulWidget {
  final LocalMedia media; final String name;
  const _AudioView({required this.media, required this.name});
  @override State<_AudioView> createState() => _AudioViewState();
}

class _AudioViewState extends State<_AudioView> {
  final player = AudioPlayer();
  final subs = <StreamSubscription<Object?>>[];
  Duration position = Duration.zero, duration = Duration.zero;
  /// While the slider is dragged.
  double? dragging;
  String? error;

  @override void initState() {
    super.initState();
    subs.add(player.positionStream.listen((p) { if (mounted) setState(() => position = p); }));
    subs.add(player.durationStream.listen((d) { if (mounted) setState(() => duration = d ?? Duration.zero); }));
    subs.add(player.playerStateStream.listen((s) async {
      if (s.processingState == ProcessingState.completed) { await player.pause(); await player.seek(Duration.zero); }
      if (mounted) setState(() {});
    }));
    open();
  }

  Future<void> open() async {
    try {
      final m = widget.media;
      m.path != null && !kIsWeb ? await player.setFilePath(m.path!) : await player.setUrl(m.source);
      await player.play();
    } catch (e) { if (mounted) setState(() => error = '$e'); }
  }

  @override void dispose() { for (final s in subs) { s.cancel(); } player.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    const white = Colors.white;
    final max = duration.inMilliseconds.toDouble();
    final value = (dragging ?? position.inMilliseconds.toDouble()).clamp(0.0, max > 0 ? max : 0.0);
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: Padding(padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.graphic_eq, size: 120, color: white),
        const SizedBox(height: 16),
        Text(widget.name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: white)),
        const SizedBox(height: 24),
        if (error != null) Text('${context.tr('mediaCannotShow')}\n$error', textAlign: TextAlign.center, style: const TextStyle(color: white))
        else ...[
          Slider(value: value, max: max > 0 ? max : 1, onChanged: max > 0 ? (v) => setState(() => dragging = v) : null,
            onChangeEnd: (v) async { await player.seek(Duration(milliseconds: v.round())); if (mounted) setState(() => dragging = null); }),
          Text('${formatDuration(Duration(milliseconds: value.round()))} / ${formatDuration(duration)}', style: const TextStyle(color: white)),
          const SizedBox(height: 12),
          IconButton(tooltip: context.tr('play'), color: white, iconSize: 72,
            onPressed: () => player.playing ? player.pause() : player.play(),
            icon: Icon(player.playing ? Icons.pause_circle : Icons.play_circle)),
        ],
      ]))));
  }
}
