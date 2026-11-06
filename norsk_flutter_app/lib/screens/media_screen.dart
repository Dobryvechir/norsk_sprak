import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/google_drive.dart';
import '../services/media_store.dart';
import 'audio_record_screen.dart';
import 'camera_capture_screen.dart';
import 'media_list_screen.dart';

/// Media: pictures, videos and audio recorded here and kept on the user's own Google Drive (with the
/// token from Settings; never through our backend). Every temporary local file is removed on leaving.
class MediaScreen extends StatefulWidget {
  const MediaScreen({super.key});
  @override State<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends State<MediaScreen> {
  final drive = GoogleDrive();

  @override void initState() { super.initState(); MediaTemp.clearAll(); } // leftovers of an interrupted visit
  @override void dispose() { MediaTemp.clearAll(); super.dispose(); }

  void open(Widget screen, {bool fullscreen = false}) =>
    Navigator.push(context, MaterialPageRoute(fullscreenDialog: fullscreen, builder: (_) => screen));

  Widget entry(IconData icon, String key, VoidCallback onTap) => Card(child: ListTile(
    leading: Icon(icon), title: Text(context.tr(key)), trailing: const Icon(Icons.chevron_right), onTap: onTap));

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('menuMedia'))),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: ListView(padding: const EdgeInsets.all(16), children: [
      entry(Icons.add_a_photo, 'mediaNewPicture', () => open(CameraCaptureScreen(drive: drive, kind: MediaKind.picture), fullscreen: true)),
      entry(Icons.videocam, 'mediaNewVideo', () => open(CameraCaptureScreen(drive: drive, kind: MediaKind.video), fullscreen: true)),
      entry(Icons.mic, 'mediaNewAudio', () => open(AudioRecordScreen(drive: drive), fullscreen: true)),
      const Divider(height: 24),
      entry(Icons.photo_library, 'mediaPictures', () => open(MediaListScreen(drive: drive, kind: MediaKind.picture))),
      entry(Icons.video_library, 'mediaVideos', () => open(MediaListScreen(drive: drive, kind: MediaKind.video))),
      entry(Icons.library_music, 'mediaAudio', () => open(MediaListScreen(drive: drive, kind: MediaKind.audio))),
    ]))),
  );
}
