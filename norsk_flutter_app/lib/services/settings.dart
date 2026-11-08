import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/l10n.dart';

/// User preferences kept in local storage (SharedPreferences; localStorage on web).
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final instance = AppSettings._();

  String uiLanguage = defaultLanguage;
  String audioLanguage = 'nb';
  List<String> textLanguages = const ['nb'];
  /// Whether the user has connected their own Google Drive (see DriveAuth); Media is shown only then.
  bool driveConnected = false;
  /// The address of the connected Google account, when the platform tells it.
  String? driveEmail;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    uiLanguage = _valid(prefs.getString('ui_language')) ?? defaultLanguage;
    audioLanguage = _valid(prefs.getString('audio_language')) ?? 'nb';
    final texts = (prefs.getStringList('text_languages') ?? const []).map(_valid).whereType<String>().toSet().toList();
    textLanguages = texts.isEmpty ? const ['nb'] : texts;
    driveConnected = prefs.getBool('drive_connected') ?? false;
    driveEmail = prefs.getString('drive_email');
    // Removes the token that used to be pasted into Settings, which is no longer used.
    try { await const FlutterSecureStorage().delete(key: 'google_drive_token'); } catch (_) {}
    notifyListeners();
  }

  /// Codes this app used before switching to the ISO ones.
  static const _oldCodes = {'cz': 'cs', 'gr': 'el', 'no': 'nb'};
  static String? _valid(String? code) { code = _oldCodes[code] ?? code; return languageNames.containsKey(code) ? code : null; }

  Future<void> setUiLanguage(String code) async {
    uiLanguage = code; notifyListeners();
    await (await SharedPreferences.getInstance()).setString('ui_language', code);
  }

  Future<void> setAudioLanguage(String code) async {
    audioLanguage = code; notifyListeners();
    await (await SharedPreferences.getInstance()).setString('audio_language', code);
  }

  /// Adds or removes a text language; the last remaining one can't be removed.
  Future<void> setTextLanguage(String code, bool selected) async {
    if (!selected && textLanguages.length == 1 && textLanguages.contains(code)) return;
    final set = {...textLanguages};
    selected ? set.add(code) : set.remove(code);
    // Keep the order of the language list, not the order of clicking.
    textLanguages = [for (final c in languageNames.keys) if (set.contains(c)) c];
    notifyListeners();
    await (await SharedPreferences.getInstance()).setStringList('text_languages', textLanguages);
  }

  Future<void> setDriveConnection(bool connected, {String? email}) async {
    driveConnected = connected; driveEmail = connected ? email : null; notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('drive_connected', connected);
    driveEmail == null ? await prefs.remove('drive_email') : await prefs.setString('drive_email', driveEmail!);
  }
}
