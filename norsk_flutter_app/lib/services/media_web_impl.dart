import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

/// A `blob:` URL for [bytes]; release it with [revokeObjectUrl].
String createObjectUrl(Uint8List bytes, String mimeType) =>
  web.URL.createObjectURL(web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType)));

void revokeObjectUrl(String url) { if (url.startsWith('blob:')) web.URL.revokeObjectURL(url); }

/// The first frame of the video at [url] as JPEG, at most [maxSize] pixels on its longer side;
/// null when the browser can't show it within a few seconds.
Future<Uint8List?> videoFrameJpeg(String url, int maxSize) async {
  final video = web.HTMLVideoElement()..muted = true..preload = 'auto'..crossOrigin = 'anonymous';
  video.setAttribute('playsinline', '');
  final ready = Completer<bool>();
  video.onloadeddata = ((web.Event _) { if (!ready.isCompleted) ready.complete(true); }).toJS;
  video.onerror = ((web.Event _) { if (!ready.isCompleted) ready.complete(false); }).toJS;
  video.src = url;
  video.load();
  try {
    if (!await ready.future.timeout(const Duration(seconds: 8), onTimeout: () => false)) return null;
    final w = video.videoWidth, h = video.videoHeight;
    if (w == 0 || h == 0) return null;
    final scale = maxSize / (w > h ? w : h);
    final cw = (w * (scale < 1 ? scale : 1)).round(), ch = (h * (scale < 1 ? scale : 1)).round();
    final canvas = web.HTMLCanvasElement()..width = cw..height = ch;
    (canvas.getContext('2d') as web.CanvasRenderingContext2D).drawImage(video, 0, 0, cw, ch);
    final dataUrl = canvas.toDataURL('image/jpeg', 0.85.toJS);
    final comma = dataUrl.indexOf(',');
    return comma < 0 ? null : base64Decode(dataUrl.substring(comma + 1));
  } catch (_) {
    return null;
  } finally {
    video.removeAttribute('src');
    video.load();
  }
}
