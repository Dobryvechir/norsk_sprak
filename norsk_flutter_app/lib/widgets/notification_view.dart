import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/entities.dart';

/// Icon, color and title for each notification level.
(IconData, Color, String) notificationStyle(BuildContext context, NotificationLevel level) {
  final scheme = Theme.of(context).colorScheme;
  return switch (level) {
    NotificationLevel.info => (Icons.info_outline, scheme.primary, context.tr('notificationInfo')),
    NotificationLevel.warning => (Icons.warning_amber_rounded, Colors.orange.shade800, context.tr('notificationWarning')),
    NotificationLevel.critical => (Icons.report_outlined, scheme.error, context.tr('notificationCritical')),
    NotificationLevel.fatal => (Icons.dangerous_outlined, Colors.red.shade900, context.tr('notificationFatal')),
  };
}

/// Shows [n] in a dialog styled by its level. Returns true when the user chose "Do not remind again"
/// (offered only for notifications that are shown until dismissed).
Future<bool> showNotificationDialog(BuildContext context, AppNotification n) async {
  final (icon, color, title) = notificationStyle(context, n.level);
  final result = await showDialog<bool>(context: context, barrierDismissible: n.level == NotificationLevel.info,
    builder: (ctx) => AlertDialog(
      icon: Icon(icon, color: color, size: 36),
      title: Text(title, style: TextStyle(color: color)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: color, width: 2)),
      content: SingleChildScrollView(child: SelectableText(n.text)),
      actions: [
        if (n.dismissible) TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('doNotRemindAgain'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('close'))),
      ]));
  return result == true;
}

/// The whole screen for a fatal notification: only the message; tapping anywhere calls [onExit].
class FatalNotificationView extends StatelessWidget {
  final AppNotification notification;
  final VoidCallback onExit;
  const FatalNotificationView({super.key, required this.notification, required this.onExit});
  @override Widget build(BuildContext context) {
    final (icon, color, title) = notificationStyle(context, NotificationLevel.fatal);
    return Scaffold(backgroundColor: color, body: InkWell(onTap: onExit, child: SafeArea(child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 64),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white)),
        const SizedBox(height: 16),
        Text(notification.text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white)),
        const SizedBox(height: 32),
        OutlinedButton.icon(onPressed: onExit, icon: const Icon(Icons.exit_to_app), label: Text(context.tr('exitApp')),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white))),
      ])))))));
  }
}
