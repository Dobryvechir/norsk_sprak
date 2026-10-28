import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
/// Placeholder for menu entries that are not implemented yet.
class ComingSoonScreen extends StatelessWidget {
  final String titleKey;
  const ComingSoonScreen({super.key, required this.titleKey});
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(context.tr(titleKey))),
    body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(context.tr('comingSoon'), style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 20),
      FilledButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back), label: Text(context.tr('back'))),
    ])));
}
