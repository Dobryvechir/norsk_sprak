/// Browser helpers for Media: `blob:` URLs for media kept in memory, and a frame of a video as an
/// image. Only available on web; elsewhere every function throws [UnsupportedError].
library;

export 'media_web_stub.dart' if (dart.library.js_interop) 'media_web_impl.dart';
