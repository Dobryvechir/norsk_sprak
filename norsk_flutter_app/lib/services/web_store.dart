/// The browser's IndexedDB, where the web app saves chapters for offline use: the chapter JSON
/// and its audio files. Only available on web; elsewhere every function throws [UnsupportedError].
library;

export 'web_store_stub.dart' if (dart.library.js_interop) 'web_store_web.dart';
