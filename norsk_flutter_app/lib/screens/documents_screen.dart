import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/document_store.dart';
import '../services/media_store.dart';
import 'camera_capture_screen.dart';
import 'document_list_screen.dart';
import 'document_save_dialog.dart';
import 'document_sync_screen.dart';
import 'document_upload_screen.dart';
import 'links_screen.dart';

/// Documents: pictures, PDFs and sheets kept permanently on this device (`document/<folder>`), links,
/// and synchronization of the files with the same folders on the user's Google Drive.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});
  @override State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  // The camera's picture is kept in the temporary Media storage until it is saved.
  @override void initState() { super.initState(); MediaTemp.clearAll(); }
  @override void dispose() { MediaTemp.clearAll(); super.dispose(); }

  void open(Widget screen, {bool fullscreen = false}) =>
    Navigator.push(context, MaterialPageRoute(fullscreenDialog: fullscreen, builder: (_) => screen));

  Widget entry(IconData icon, String key, VoidCallback onTap) => Card(child: ListTile(
    leading: Icon(icon), title: Text(context.tr(key)), trailing: const Icon(Icons.chevron_right), onTap: onTap));

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('menuDocuments'))),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: ListView(padding: const EdgeInsets.all(16), children: [
      entry(DocFolder.pictures.icon, 'docPictures', () => open(const DocumentListScreen(folder: DocFolder.pictures))),
      entry(DocFolder.pdf.icon, 'docPdf', () => open(const DocumentListScreen(folder: DocFolder.pdf))),
      entry(DocFolder.sheets.icon, 'docSheets', () => open(const DocumentListScreen(folder: DocFolder.sheets))),
      const Divider(height: 24),
      entry(Icons.add_a_photo, 'docCameraPicture', () => open(CameraCaptureScreen(kind: MediaKind.picture,
        onCaptured: (context, media, _) => showDocumentSaveDialog(context, media)), fullscreen: true)),
      entry(Icons.upload_file, 'docUpload', () => open(const DocumentUploadScreen())),
      entry(Icons.link, 'docLinks', () => open(const LinksScreen())),
      const Divider(height: 24),
      entry(Icons.sync, 'docSync', () => open(const DocumentSyncScreen())),
    ]))),
  );
}
