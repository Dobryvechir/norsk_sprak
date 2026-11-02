{{flutter_js}}
{{flutter_build_config}}
// Loads the app without Flutter's own service worker: Flutter's generated one only unregisters itself
// (which would also remove ours), so the app registers offline_sw.js instead (see index.html).
_flutter.loader.load();
