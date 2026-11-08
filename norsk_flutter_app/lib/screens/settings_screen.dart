import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/api.dart';
import '../services/dictionaries.dart';
import '../services/drive_auth.dart';
import '../services/settings.dart';
import 'dictionaries_screen.dart';
/// Language preferences and the connection to the user's Google Drive, kept locally on this device.
class SettingsScreen extends StatelessWidget {
  final Api api;
  const SettingsScreen({super.key, required this.api});
  @override Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    Widget languagePicker(String label, String value, ValueChanged<String> onChanged) => InputDecorator(
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: value, isExpanded: true, isDense: true,
        items: [for (final e in languageNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) { if (v != null) onChanged(v); })));
    return Scaffold(appBar: AppBar(title: Text(context.tr('menuSettings'))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: ListView(padding: const EdgeInsets.all(16), children: [
        languagePicker(context.tr('uiLanguage'), settings.uiLanguage, settings.setUiLanguage),
        const SizedBox(height: 16),
        languagePicker(context.tr('audioLanguage'), settings.audioLanguage, settings.setAudioLanguage),
        const SizedBox(height: 24),
        Text(context.tr('textLanguages'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(context.tr('textLanguagesHint')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in languageNames.entries) FilterChip(label: Text(e.value),
            selected: settings.textLanguages.contains(e.key), onSelected: (on) => settings.setTextLanguage(e.key, on)),
        ]),
        const SizedBox(height: 24),
        const _DriveConnection(),
        const SizedBox(height: 24),
        OutlinedButton.icon(icon: const Icon(Icons.menu_book), label: Text(context.tr('manageDictionaries')),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DictionariesScreen(dictionaries: Dictionaries(api))))),
      ]))));
  }
}

/// Connects the user's own Google Drive, for Media, document synchronization and Chat attachments.
class _DriveConnection extends StatefulWidget {
  const _DriveConnection();
  @override State<_DriveConnection> createState() => _DriveConnectionState();
}
class _DriveConnectionState extends State<_DriveConnection> {
  bool busy = false;
  String? error;

  Future<void> run(Future<void> Function() action) async {
    setState(() { busy = true; error = null; });
    try { await action(); }
    on DriveException catch (e) { if (mounted) setState(() => error = e.message); }
    finally { if (mounted) setState(() => busy = false); }
  }

  @override Widget build(BuildContext context) {
    final auth = DriveAuth.instance, theme = Theme.of(context);
    return ListenableBuilder(listenable: AppSettings.instance, builder: (context, _) {
      final settings = AppSettings.instance, email = settings.driveEmail;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!settings.driveConnected)
          OutlinedButton.icon(icon: const Icon(Icons.add_to_drive), label: Text(context.tr('driveConnect')),
            onPressed: busy || !auth.configured ? null : () => run(auth.connect))
        else ...[
          Row(children: [
            const Icon(Icons.add_to_drive),
            const SizedBox(width: 12),
            Expanded(child: Text(email == null ? context.tr('driveConnected') : context.tr('driveConnectedAs', {'email': email}))),
          ]),
          const SizedBox(height: 8),
          Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
            TextButton(onPressed: busy ? null : () => run(auth.connect), child: Text(context.tr('driveReconnectAction'))),
            TextButton(onPressed: busy ? null : () => run(auth.disconnect), child: Text(context.tr('driveDisconnect'))),
          ]),
        ],
        const SizedBox(height: 4),
        Text(context.tr(auth.configured ? 'driveConnectHint' : 'driveNotConfigured'), style: theme.textTheme.bodySmall),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: theme.colorScheme.error))),
      ]);
    });
  }
}
