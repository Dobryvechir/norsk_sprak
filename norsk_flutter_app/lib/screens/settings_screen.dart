import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/settings.dart';
/// Language preferences, stored locally on this device.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
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
      ]))));
  }
}
