import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/document_store.dart';
import '../services/document_sync.dart';
import '../services/google_drive.dart';
import '../services/settings.dart';

/// Synchronizes the documents on this device with the same folders on Google Drive (see
/// [DocumentSync]), then shows what was done; conflicting files can be listed in a table.
class DocumentSyncScreen extends StatefulWidget {
  const DocumentSyncScreen({super.key});
  @override State<DocumentSyncScreen> createState() => _DocumentSyncScreenState();
}

class _DocumentSyncScreenState extends State<DocumentSyncScreen> {
  bool running = false;
  int done = 0, total = 0;
  String current = '';
  SyncReport? report;
  String? error;

  Future<void> start() async {
    setState(() { running = true; report = null; error = null; done = 0; total = 0; current = ''; });
    try {
      final r = await DocumentSync(GoogleDrive(), DocumentStore.instance).run(onProgress: (d, t, name) {
        if (mounted) setState(() { done = d; total = t; current = name; });
      });
      if (mounted) setState(() => report = r);
    } catch (e) {
      if (mounted) setState(() => error = e is DriveException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  void showConflicts(SyncReport r) => Navigator.push(context, MaterialPageRoute(builder: (_) => _ConflictsScreen(conflicts: r.conflicts)));

  @override Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasToken = AppSettings.instance.googleDriveToken.isNotEmpty;
    final r = report;
    Widget stat(IconData icon, String key, int count, {Color? color}) =>
      ListTile(dense: true, leading: Icon(icon, color: color), title: Text(context.tr(key, {'count': count})));
    return PopScope(canPop: !running, child: Scaffold(
      appBar: AppBar(title: Text(context.tr('docSync')), automaticallyImplyLeading: !running),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: ListView(padding: const EdgeInsets.all(16), children: [
        Text(context.tr('syncInfo'), style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        if (!hasToken) Text(context.tr('driveTokenMissing'), style: TextStyle(color: theme.colorScheme.error)),
        FilledButton.icon(onPressed: running || !hasToken ? null : start, icon: const Icon(Icons.sync), label: Text(context.tr('syncStart'))),
        if (running) ...[
          const SizedBox(height: 24),
          LinearProgressIndicator(value: total == 0 ? null : done / total),
          const SizedBox(height: 8),
          Text(total == 0 ? context.tr('syncListing') : context.tr('syncProgress', {'done': done, 'total': total, 'name': current}),
            maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
        if (error != null) Padding(padding: const EdgeInsets.only(top: 24), child: Text(error!, style: TextStyle(color: theme.colorScheme.error))),
        if (r != null) ...[
          const SizedBox(height: 24),
          Text(context.tr('syncDone'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(child: Column(children: [
            stat(Icons.cloud_upload_outlined, 'syncUploaded', r.uploaded),
            stat(Icons.cloud_download_outlined, 'syncDownloaded', r.downloaded),
            stat(Icons.check_circle_outline, 'syncUnchanged', r.unchanged, color: Colors.green),
            stat(Icons.sync_problem, 'syncConflicts', r.conflicts.length, color: r.conflicts.isEmpty ? null : theme.colorScheme.tertiary),
            if (r.errors.isNotEmpty) stat(Icons.error_outline, 'syncErrors', r.errors.length, color: theme.colorScheme.error),
          ])),
          if (r.conflicts.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(onPressed: () => showConflicts(r), icon: const Icon(Icons.table_chart_outlined), label: Text(context.tr('syncViewConflicts')))),
          if (r.errors.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final e in r.errors) Padding(padding: const EdgeInsets.only(bottom: 4),
              child: Text(e, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error))),
          ],
        ],
      ]))),
    ));
  }
}

class _ConflictsScreen extends StatelessWidget {
  final List<SyncConflict> conflicts;
  const _ConflictsScreen({required this.conflicts});
  @override Widget build(BuildContext context) {
    String size(int bytes) => '${formatBytes(bytes)} ($bytes)';
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('syncConflictsTitle'))),
      body: SingleChildScrollView(padding: const EdgeInsets.all(12), child: SingleChildScrollView(scrollDirection: Axis.horizontal,
        child: DataTable(columns: [
          DataColumn(label: Text(context.tr('syncFolder'))),
          DataColumn(label: Text(context.tr('syncFile'))),
          DataColumn(label: Text(context.tr('syncLocalSize')), numeric: true),
          DataColumn(label: Text(context.tr('syncDriveSize')), numeric: true),
        ], rows: [
          for (final c in conflicts) DataRow(cells: [
            DataCell(Text(c.folder.path)),
            DataCell(Text(c.name)),
            DataCell(Text(size(c.localSize))),
            DataCell(Text(size(c.driveSize))),
          ]),
        ]))),
    );
  }
}
