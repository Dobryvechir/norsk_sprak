import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';
import '../l10n/l10n.dart';
import 'google_client_ids.dart';
import 'settings.dart';

/// An error from Google Drive or from connecting to it, with a message for the user.
class DriveException implements Exception {
  final String message;
  const DriveException(this.message);
  @override String toString() => message;
}

/// Everything in the user's Drive: Media, Documents and Chat use folders in My Drive, and
/// synchronization must also see the files added there outside this app.
const driveScopes = ['https://www.googleapis.com/auth/drive'];

/// What [DriveAuth] needs from Google Sign-In (replaced in tests).
abstract class DriveTokenSource {
  bool get configured;
  /// An access token obtained without showing anything, or null when that isn't possible.
  Future<String?> silentToken();
  /// An access token, showing Google's sign-in or consent when needed. Throws when that fails.
  Future<String> interactiveToken();
  /// The signed-in account's address, when the platform tells it (the web flow doesn't).
  String? get email;
  Future<void> clearToken(String token);
  Future<void> signOut();
  Future<void> disconnect();
}

/// The connection to the user's own Google Drive. Tokens stay on this device, and only "connected"
/// and the address are saved (see [AppSettings]): Google's own SDK keeps the sign-in.
///
/// Android and iOS renew tokens silently. The web SDK has no silent renewal: its token lives for an
/// hour in memory only, and after that the next Drive action opens a popup, which closes by itself
/// when access was already granted, and can be blocked unless it follows a tap.
class DriveAuth {
  DriveAuth([DriveTokenSource? source]) : _source = source ?? _GoogleSignInTokens();
  static final instance = DriveAuth();
  final DriveTokenSource _source;
  /// The request under way, shared so that parallel Drive calls can't open several sign-in popups.
  Future<String>? _pending;

  bool get configured => _source.configured;

  /// A token for Drive; [rejected] is one Drive has just refused, which must not be returned again.
  Future<String> token({String? rejected}) => _pending ??= _fetch(rejected).whenComplete(() => _pending = null);

  Future<String> _fetch(String? rejected) async {
    if (!AppSettings.instance.driveConnected) throw DriveException(trNow('driveNotConnected'));
    try {
      if (rejected != null) await _source.clearToken(rejected);
      return await _source.silentToken() ?? await _source.interactiveToken();
    } on GoogleSignInException catch (e) {
      throw DriveException(switch (e.code) {
        GoogleSignInExceptionCode.canceled || GoogleSignInExceptionCode.interrupted || GoogleSignInExceptionCode.uiUnavailable => trNow('driveReconnect'),
        _ => trNow('driveError', {'error': e.description ?? e.code.name}),
      });
    } on PlatformException catch (e) {
      throw DriveException(trNow('driveError', {'error': e.message ?? e.code}));
    }
  }

  /// Signs in and asks for access to Drive, from a button. Returns false when the user cancels.
  Future<bool> connect() async {
    if (!configured) throw DriveException(trNow('driveNotConfigured'));
    try {
      await _source.interactiveToken();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      throw DriveException(trNow('driveError', {'error': e.description ?? e.code.name}));
    } on PlatformException catch (e) {
      throw DriveException(trNow('driveError', {'error': e.message ?? e.code}));
    }
    await AppSettings.instance.setDriveConnection(true, email: _source.email);
    return true;
  }

  /// Forgets the connection on this device, and asks Google to revoke the access where it can.
  Future<void> disconnect() async {
    await AppSettings.instance.setDriveConnection(false);
    try { await _source.disconnect(); } catch (_) {} // already forgotten here, which is what the user sees
  }

  /// For logging out of the app: the next user of this device must not get this Drive. Never holds up
  /// the logout, and leaves the access granted, so connecting again only needs the account chosen.
  void signOut() {
    if (!AppSettings.instance.driveConnected) return;
    unawaited(AppSettings.instance.setDriveConnection(false));
    unawaited(_source.signOut().catchError((Object _) {}));
  }
}

/// [DriveTokenSource] with the `google_sign_in` package: an account on Android and iOS, and on web
/// only the access token, since the web SDK allows signing in only through its own button.
class _GoogleSignInTokens implements DriveTokenSource {
  static GoogleSignIn get _signIn => GoogleSignIn.instance;
  static bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The package allows only one initialization.
  Future<void>? _initialized;
  GoogleSignInAccount? _account;

  Future<void> _ready() => _initialized ??= _signIn.initialize(
    clientId: kIsWeb ? googleWebClientId : _ios ? googleIosClientId : null,
    serverClientId: _android ? googleWebClientId : null);

  GoogleSignInAuthorizationClient get _client => _account?.authorizationClient ?? _signIn.authorizationClient;

  @override bool get configured => kIsWeb || _android ? googleWebClientId.isNotEmpty : _ios && googleIosClientId.isNotEmpty;
  @override String? get email => _account?.email;

  @override Future<String?> silentToken() async {
    await _ready();
    if (!kIsWeb) {
      // After a restart the account must be restored first (web needs none; see the class comment).
      _account ??= await _signIn.attemptLightweightAuthentication();
      if (_account == null) return null;
    }
    return (await _client.authorizationForScopes(driveScopes))?.accessToken;
  }

  @override Future<String> interactiveToken() async {
    await _ready();
    if (!kIsWeb) _account ??= await _signIn.authenticate(scopeHint: driveScopes);
    final client = _client;
    return (await client.authorizationForScopes(driveScopes) ?? await client.authorizeScopes(driveScopes)).accessToken;
  }

  @override Future<void> clearToken(String token) async {
    await _ready();
    await _client.clearAuthorizationToken(accessToken: token);
  }

  @override Future<void> signOut() async {
    await _ready();
    _account = null;
    await _signIn.signOut();
  }

  @override Future<void> disconnect() async {
    // Android can revoke access only for an account authorized since the app started.
    try { await silentToken(); } catch (_) {}
    _account = null;
    await _signIn.disconnect();
  }
}
