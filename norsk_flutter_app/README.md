# Norsk Audio Groups — Flutter mobile client

A Flutter (Dart) client for the **Norsk Audio Groups FastAPI backend** provided earlier. Intended for Android first and iOS later. This archive contains complete application Dart source, dependencies and a unit test. **The Flutter-generated Android/iOS runner directories are not included**; generate them with `flutter create --platforms=android,ios .` (see below). No compiled APK/IPA is included.

## Features

- Login with server URL, email and password; token in OS-backed secure storage.
- List groups assigned to the signed-in user.
- List group recordings, status, duration and sentence count.
- Import and upload supported audio formats (server enforces role and quota).
- Download authorized audio via Bearer token, cache it locally, play it offline after download.
- Transcript display, tap-to-seek, repeat each sentence 1–20 times, previous/next, playback speed 0.5–1.5×.
- Refresh pending transcription results; authorized uploaders/admins can edit sentence text and milliseconds, retry failed jobs; admins can delete recordings.
- Group administration: list/edit membership roles and quotas, add existing user by ID. System admins can create groups and users.

## Prerequisites

- Flutter stable SDK with Dart >= 3.4, Android SDK and a configured emulator or Android device.
- For iOS builds: macOS with Xcode, or an appropriate remote/cloud iOS build system.
- Running compatible FastAPI backend (see its README). Set `APP_SECRET`, bootstrap administrator and OpenAI key on the **server**, never in the mobile app.

## Create native runner files and run

```bash
unzip norsk_flutter_app.zip
cd norsk_flutter_app
flutter create --platforms=android,ios .
flutter pub get
flutter analyze
flutter test
flutter run
```

For an Android release build:

```bash
flutter build apk --release
```

The APK will be under `build/app/outputs/flutter-apk/`. Release signing and store publication require additional setup.

### Android Internet permission

Check `android/app/src/main/AndroidManifest.xml` contains the following as a direct child of `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

For production, use an HTTPS server URL with a valid certificate. Android/iOS block or restrict cleartext HTTP by default; do **not** disable transport security globally. For Android emulator local development, `http://10.0.2.2:8000` may be reachable if FastAPI listens on the host network and Android cleartext traffic is explicitly allowed in a **debug-only** configuration. Physical devices need a reachable host address.

### iOS

For network connections use HTTPS. If using a local HTTP server for debugging, configure a narrowly scoped ATS exception in the generated iOS project only for that development environment. Add Xcode signing and deploy to an iOS device.

## Backend API compatibility

This client targets the exact endpoints from the supplied `norsk_audio_backend.zip`:

- `POST /api/auth/login`, `GET /api/me`, `GET /api/me/groups`
- `GET /api/groups/{gid}/recordings`, `POST /api/groups/{gid}/recordings`
- `GET /api/recordings/{rid}`, `GET /api/recordings/{rid}/audio`
- `PATCH /api/recordings/{rid}/sentences/{index}`
- `POST /api/recordings/{rid}/transcribe`, `DELETE /api/recordings/{rid}`
- `GET /api/groups/{gid}/members`, `PUT /api/groups/{gid}/members/{user_id}`
- `POST /api/admin/groups`, `POST /api/admin/users`

**Known backend integration limitations:**

1. The backend does not expose the current user's per-group role or a user-directory lookup. Therefore, the app shows upload/edit/admin actions optimistically, and the server returns 403 when a viewer attempts them. The admin Add Member form requires an existing **user ID**, not email. For a better UX, extend the backend with `GET /api/groups/{gid}/my-membership` and an admin-only user lookup endpoint, then conditionally show controls.
2. The create-user flow displays the newly created user ID, but does not automatically add that user to a group. The administrator can copy the ID into Add Member.
3. Audio caching is **per recording ID, not per signed-in user**. On a shared device, locally downloaded audio could remain after logout; the app should be extended to partition and purge caches by user for a security-sensitive deployment. Only use the MVP on trusted devices.
4. Transcript metadata is fetched from the server; offline playback of cached audio works while a player screen is already loaded, but fully offline library/transcript browsing is **not yet implemented**.
5. Sentence boundaries are checked using `just_audio.positionStream` and are not sample-accurate. There may be small overshoots/gaps. Validate with real recordings; for tighter repetition consider native clipped playback or precomputed segments.
6. No automatic periodic polling; tap Refresh to get new transcription status. A future update can add periodic refresh while the screen is open.
7. JSON metadata mode in the backend is not transactional across worker/API processes. Its security and concurrency caveats still apply.
8. No offline upload queue, no resumable client uploads, and no per-group AI credential UI yet (the backend does not support credential IDs). Long uploads should use reliable Wi-Fi.
9. Flutter SDK is not installed in the artifact-generation environment, so `flutter analyze`, `flutter test`, Android build and iOS build could **not** be executed here. Run these locally after generating platform runners.

## Project structure

```
lib/
  main.dart
  models/entities.dart
  services/api.dart
  services/audio_cache.dart
  services/sentence_player.dart
  screens/login_screen.dart
  screens/groups_screen.dart
  screens/library_screen.dart
  screens/upload_screen.dart
  screens/player_screen.dart
  screens/admin_screen.dart
test/entities_test.dart
pubspec.yaml
analysis_options.yaml
```

## Google Drive sign-in

Media, document synchronization and Chat attachments use the user's own Google Drive, connected in Settings with Google Sign-In (Android, iOS and web). The app calls Drive directly; nothing goes through the backend. Until the client IDs below are set, Settings says sign-in isn't set up and Drive can't be connected.

In a [Google Cloud](https://console.cloud.google.com/) project:

1. Enable the **Google Drive API**.
2. Configure the OAuth consent screen and add the scope `https://www.googleapis.com/auth/drive`. While its status is "Testing", add each Google account as a test user. Google's restricted-scope verification is needed before publishing.
3. Under Credentials, create these OAuth clients:

| Type | Settings | Where it goes |
|---|---|---|
| Web application | Authorized JavaScript origins: `http://localhost`, `http://localhost:7357` (used by `kjører_web.bat`) and the origin the app is hosted on | `googleWebClientId` in `lib/services/google_client_ids.dart` (Android uses it too) |
| Android | Package `com.example.norsk_audio_groups`, plus the SHA-1 of each signing key, debug and release (`keytool -list -v -keystore <keystore>`) | Nothing: Google recognizes the app by these |
| iOS | Bundle ID `com.example.norskAudioGroups` | `googleIosClientId` in `lib/services/google_client_ids.dart`, and its reversed form as `GOOGLE_REVERSED_CLIENT_ID` in `ios/Flutter/GoogleSignIn.xcconfig` |

The reversed form of `123-abc.apps.googleusercontent.com` is `com.googleusercontent.apps.123-abc`. These client IDs are not secrets. If the package name or bundle ID changes, change the client too.

Renewal differs by platform. Android and iOS renew the access token silently. On web, Google offers no silent renewal: the token lasts an hour and is lost on reload, and then the next Drive action opens a popup, which closes by itself if access was already granted. If the browser blocks it, the user is asked to reconnect in Settings.

## Security considerations

- Use HTTPS for remote connections.
- Do not embed AI API keys or Google Drive credentials in Flutter.
- Backend must check group membership and role on every protected endpoint.
- Implement user-specific audio cache isolation and cache deletion on logout before supporting untrusted/shared devices.
- The server currently issues 7-day bearer tokens without revocation; improve session handling before production.
- The backend currently returns full recording transcripts and group names to authorized members; this is intended shared-group behavior.
