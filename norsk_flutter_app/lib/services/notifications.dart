import 'package:shared_preferences/shared_preferences.dart';
import '../models/entities.dart';
import 'api.dart';

/// Decides which of the server's notifications to show, and remembers on this device (per user)
/// the ones not to show again: "show once" notifications after they were shown, and those
/// where the user chose "Do not remind again".
class NotificationCenter {
  final Api api;
  NotificationCenter(this.api);

  static String _key(String userId) => 'dismissed_notifications_$userId';

  Future<Set<String>> dismissed(String userId) async =>
    ((await SharedPreferences.getInstance()).getStringList(_key(userId)) ?? const <String>[]).toSet();

  Future<void> dismiss(String userId, String id) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = {...?prefs.getStringList(_key(userId)), id};
    await prefs.setStringList(_key(userId), ids.toList());
  }

  /// Which of [all] to show now, most severe first: fatal and "every time" ones always,
  /// the others unless their id is in [dismissed].
  static List<AppNotification> toShow(List<AppNotification> all, Set<String> dismissed) =>
    all.where((n) => n.isFatal || n.showAlways || !dismissed.contains(n.id)).toList()
      ..sort((a, b) => b.severity.compareTo(a.severity));

  /// The notifications to show to the logged-in user now; empty when offline or the server can't be reached.
  Future<List<AppNotification>> pending() async {
    final user = api.user;
    if (user == null || api.offline) return const [];
    try { return toShow(await api.myNotifications(), await dismissed(user.id)); }
    catch (_) { return const []; }
  }
}
