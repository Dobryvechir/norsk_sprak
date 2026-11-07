/// The browser's IndexedDB, where the web app keeps Documents permanently. Only available on web;
/// elsewhere every function throws [UnsupportedError].
library;

export 'document_web_stub.dart' if (dart.library.js_interop) 'document_web_impl.dart';
