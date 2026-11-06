import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../services/google_drive.dart';
import '../services/media_store.dart';
import 'media_save_dialog.dart';

/// Takes a picture or records a video with the camera: shutter or record/pause/stop, camera switch,
/// flash, zoom and tap-to-focus. The result is kept temporarily on this device and then offered for
/// saving to Google Drive (see [showMediaSaveDialog]); either way the screen then closes.
class CameraCaptureScreen extends StatefulWidget {
  final GoogleDrive drive; final MediaKind kind;
  const CameraCaptureScreen({super.key, required this.drive, required this.kind})
    : assert(kind != MediaKind.audio);
  @override State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> with WidgetsBindingObserver {
  List<CameraDescription> cameras = const [];
  int cameraIndex = 0;
  CameraController? controller;
  String? error;
  bool busy = false;
  FlashMode flash = FlashMode.off;
  bool flashSupported = !kIsWeb;
  double zoom = 1, minZoom = 1, maxZoom = 1;
  Duration elapsed = Duration.zero;
  Timer? timer;

  bool get isVideo => widget.kind == MediaKind.video;
  bool get recording => controller?.value.isRecordingVideo ?? false;
  bool get paused => controller?.value.isRecordingPaused ?? false;

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    start();
  }

  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    controller?.dispose();
    super.dispose();
  }

  /// The camera is released while the app is in the background, and opened again on return.
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = controller;
    if (kIsWeb || c == null || !c.value.isInitialized || busy) return; // a browser tab keeps its camera
    if (state == AppLifecycleState.inactive && !recording) {
      controller = null; c.dispose(); if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && controller == null && cameras.isNotEmpty) {
      open(cameras[cameraIndex]);
    }
  }

  Future<void> start() async {
    try {
      cameras = await availableCameras();
      if (cameras.isEmpty) { setState(() => error = context.tr('noCamera')); return; }
      final back = cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      cameraIndex = back < 0 ? 0 : back;
      await open(cameras[cameraIndex]);
    } catch (e) { if (mounted) setState(() => error = cameraError(e)); }
  }

  String cameraError(Object e) {
    if (e is CameraException) {
      if (e.code.contains('AccessDenied') || e.code.contains('Permission')) return context.tr('cameraPermissionDenied');
      return e.description ?? e.code;
    }
    return '$e';
  }

  Future<void> open(CameraDescription camera) async {
    final old = controller;
    setState(() { controller = null; error = null; });
    await old?.dispose();
    final c = CameraController(camera, ResolutionPreset.high, enableAudio: isVideo);
    try {
      await c.initialize();
      if (!mounted) { await c.dispose(); return; }
      try { minZoom = await c.getMinZoomLevel(); maxZoom = await c.getMaxZoomLevel(); } catch (_) { minZoom = maxZoom = 1; }
      zoom = minZoom;
      if (flashSupported) {
        try { await c.setFlashMode(flash); } catch (_) { flashSupported = false; }
      }
      setState(() => controller = c);
    } catch (e) {
      await c.dispose();
      if (mounted) setState(() => error = cameraError(e));
    }
  }

  Future<void> switchCamera() async {
    if (cameras.length < 2 || busy || recording) return;
    cameraIndex = (cameraIndex + 1) % cameras.length;
    await open(cameras[cameraIndex]);
  }

  /// Off → auto → on (→ torch for video) → off.
  Future<void> nextFlash() async {
    final c = controller; if (c == null) return;
    final modes = [FlashMode.off, FlashMode.auto, FlashMode.always, if (isVideo) FlashMode.torch];
    final next = modes[(modes.indexOf(flash) + 1) % modes.length];
    try { await c.setFlashMode(next); setState(() => flash = next); }
    catch (e) { showError(cameraError(e)); }
  }

  IconData get flashIcon => switch (flash) {
    FlashMode.off => Icons.flash_off, FlashMode.auto => Icons.flash_auto,
    FlashMode.always => Icons.flash_on, FlashMode.torch => Icons.highlight,
  };

  Future<void> setZoom(double value) async {
    setState(() => zoom = value);
    try { await controller?.setZoomLevel(value); } catch (_) {}
  }

  Future<void> focusAt(TapUpDetails details, BoxConstraints box) async {
    final c = controller; if (c == null) return;
    final point = Offset(details.localPosition.dx / box.maxWidth, details.localPosition.dy / box.maxHeight);
    try {
      if (c.value.focusPointSupported) await c.setFocusPoint(point);
      if (c.value.exposurePointSupported) await c.setExposurePoint(point);
    } catch (_) {}
  }

  void showError(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> takePicture() async {
    final c = controller; if (c == null || busy || c.value.isTakingPicture) return;
    setState(() => busy = true);
    try {
      final file = await c.takePicture();
      final media = await MediaTemp.adopt(file, MediaKind.picture);
      await finish(media);
    } catch (e) { showError(cameraError(e)); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> startRecording() async {
    final c = controller; if (c == null || busy) return;
    try {
      await c.startVideoRecording();
      elapsed = Duration.zero;
      timer = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted && !paused) setState(() => elapsed += const Duration(seconds: 1)); });
      setState(() {});
    } catch (e) { showError(cameraError(e)); }
  }

  Future<void> pauseResume() async {
    final c = controller; if (c == null || !recording) return;
    try { paused ? await c.resumeVideoRecording() : await c.pauseVideoRecording(); setState(() {}); }
    catch (e) { showError(cameraError(e)); }
  }

  Future<void> stopRecording() async {
    final c = controller; if (c == null || !recording || busy) return;
    setState(() => busy = true);
    timer?.cancel();
    try {
      final file = await c.stopVideoRecording();
      final media = await MediaTemp.adopt(file, MediaKind.video);
      await finish(media, duration: elapsed);
    } catch (e) { showError(cameraError(e)); }
    finally { if (mounted) setState(() => busy = false); }
  }

  /// Offers [media] for saving, then returns to the Media page.
  Future<void> finish(LocalMedia media, {Duration? duration}) async {
    try { await controller?.pausePreview(); } catch (_) {}
    if (!mounted) { await media.delete(); return; }
    await showMediaSaveDialog(context, widget.drive, media, duration: duration);
    if (mounted) Navigator.pop(context);
  }

  /// Leaving without saving: a recording in progress is stopped and thrown away.
  Future<void> close() async {
    final c = controller;
    if (c != null && recording) {
      timer?.cancel();
      try { final file = await c.stopVideoRecording(); await (await MediaTemp.adopt(file, MediaKind.video)).delete(); } catch (_) {}
    }
    if (mounted) Navigator.pop(context);
  }

  @override Widget build(BuildContext context) {
    final c = controller;
    const white = Colors.white;
    Widget round(IconData icon, String tooltip, VoidCallback? onPressed) => IconButton(tooltip: tooltip, onPressed: onPressed,
      iconSize: 30, color: white, disabledColor: Colors.white38, style: IconButton.styleFrom(backgroundColor: Colors.black38), icon: Icon(icon));
    final Widget shutter = isVideo
      ? IconButton(tooltip: context.tr(recording ? 'stopRecording' : 'startRecording'), iconSize: 72,
          onPressed: c == null || busy ? null : (recording ? stopRecording : startRecording),
          icon: Icon(recording ? Icons.stop_circle : Icons.fiber_manual_record, color: recording ? white : Colors.red))
      : IconButton(tooltip: context.tr('takePicture'), iconSize: 72, onPressed: c == null || busy ? null : takePicture,
          icon: const Icon(Icons.camera, color: white));
    return PopScope(canPop: !recording && !busy, onPopInvokedWithResult: (didPop, _) { if (!didPop && !busy) close(); },
      child: Scaffold(backgroundColor: Colors.black, body: SafeArea(child: Stack(children: [
        Positioned.fill(child: error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: white))))
          : c == null || !c.value.isInitialized ? const Center(child: CircularProgressIndicator())
          : Center(child: CameraPreview(c, child: LayoutBuilder(builder: (_, box) =>
              GestureDetector(behavior: HitTestBehavior.opaque, onTapUp: (d) => focusAt(d, box))))) ),
        // Top: close, recording time, flash.
        Positioned(left: 8, top: 8, right: 8, child: Row(children: [
          round(Icons.close, context.tr('close'), busy ? null : close),
          const Spacer(),
          if (recording) Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: paused ? Colors.black54 : Colors.red, borderRadius: BorderRadius.circular(12)),
            child: Text(formatDuration(elapsed), style: const TextStyle(color: white, fontWeight: FontWeight.w600))),
          const Spacer(),
          if (flashSupported && c != null) round(flashIcon, context.tr('flash'), busy ? null : nextFlash) else const SizedBox(width: 48),
        ])),
        // Bottom: zoom, then switch camera / shutter / pause.
        if (c != null) Positioned(left: 16, right: 16, bottom: 12, child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (maxZoom > minZoom) Row(children: [
            const Icon(Icons.zoom_out, color: white),
            Expanded(child: Slider(value: zoom.clamp(minZoom, maxZoom), min: minZoom, max: maxZoom, onChanged: setZoom)),
            Text('${zoom.toStringAsFixed(1)}×', style: const TextStyle(color: white)),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            SizedBox(width: 56, child: cameras.length > 1 && !recording
              ? round(Icons.cameraswitch, context.tr('switchCamera'), busy ? null : switchCamera) : null),
            busy && !recording ? const SizedBox(width: 88, height: 88, child: Center(child: CircularProgressIndicator())) : shutter,
            SizedBox(width: 56, child: isVideo && recording
              ? round(paused ? Icons.play_arrow : Icons.pause, context.tr(paused ? 'resume' : 'pause'), busy ? null : pauseResume) : null),
          ]),
        ])),
      ]))));
  }
}
