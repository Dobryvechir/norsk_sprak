import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/api.dart';
import '../services/dictionaries.dart';
import '../services/settings.dart';
import 'dictionaries_screen.dart';
/// Language preferences and the personal Google Drive token, stored locally on this device.
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
        const _DriveTokenField(),
        const SizedBox(height: 24),
        OutlinedButton.icon(icon: const Icon(Icons.menu_book), label: Text(context.tr('manageDictionaries')),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DictionariesScreen(dictionaries: Dictionaries(api))))),
      ]))));
  }
}

/// The personal Google Drive token for Media: saved as typed, only on this device (never on our backend).
class _DriveTokenField extends StatefulWidget {
  const _DriveTokenField();
  @override State<_DriveTokenField> createState() => _DriveTokenFieldState();
}
class _DriveTokenFieldState extends State<_DriveTokenField> {
  late final controller = TextEditingController(text: AppSettings.instance.googleDriveToken);
  bool hidden = true;
  @override void dispose() { controller.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => TextField(controller: controller, obscureText: hidden,
    autocorrect: false, enableSuggestions: false, onChanged: AppSettings.instance.setGoogleDriveToken,
    decoration: InputDecoration(labelText: context.tr('googleDriveToken'), helperText: context.tr('googleDriveTokenHint'), helperMaxLines: 3,
      border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.add_to_drive),
      suffixIcon: IconButton(tooltip: context.tr(hidden ? 'show' : 'hide'), onPressed: () => setState(() => hidden = !hidden),
        icon: Icon(hidden ? Icons.visibility : Icons.visibility_off))));
}
