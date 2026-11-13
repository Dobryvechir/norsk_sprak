import 'package:flutter/material.dart';

/// Shows [child] (content of width/height [aspectRatio]) as large as the available space allows,
/// centred and without distortion. A landscape child on a portrait screen is turned 90° clockwise,
/// so it fills the screen when the device is turned sideways.
class FullView extends StatelessWidget {
  final double aspectRatio; final Widget child;
  const FullView({super.key, required this.aspectRatio, required this.child});

  @override Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
    final w = box.maxWidth, h = box.maxHeight;
    if (!w.isFinite || !h.isFinite || aspectRatio <= 0 || !aspectRatio.isFinite) return Center(child: child);
    final rotate = aspectRatio > 1 && w < h;
    final a = rotate ? 1 / aspectRatio : aspectRatio; // width/height of the box as it lies on screen
    var bw = w, bh = w / a;
    if (bh > h) { bh = h; bw = h * a; }
    return Center(child: SizedBox(width: bw, height: bh,
      child: rotate ? RotatedBox(quarterTurns: 1, child: child) : child));
  });
}

/// A picture from [image] shown with [FullView] (zoomable), with [error] if it cannot be decoded.
class FullImage extends StatefulWidget {
  final ImageProvider image; final Widget error;
  const FullImage({super.key, required this.image, required this.error});
  @override State<FullImage> createState() => _FullImageState();
}

class _FullImageState extends State<FullImage> {
  ImageStream? stream;
  late final listener = ImageStreamListener(
    (info, _) { if (mounted) setState(() => aspect = info.image.width / info.image.height); },
    onError: (_, __) { if (mounted) setState(() => failed = true); });
  double? aspect;
  bool failed = false;

  @override void didChangeDependencies() { super.didChangeDependencies(); resolve(); }
  @override void didUpdateWidget(FullImage old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) { aspect = null; failed = false; resolve(); }
  }

  void resolve() {
    final next = widget.image.resolve(createLocalImageConfiguration(context));
    if (next.key == stream?.key) return;
    stream?.removeListener(listener);
    stream = next..addListener(listener);
  }

  @override void dispose() { stream?.removeListener(listener); super.dispose(); }

  @override Widget build(BuildContext context) {
    if (failed) return widget.error;
    final a = aspect;
    if (a == null) return const Center(child: CircularProgressIndicator());
    return InteractiveViewer(maxScale: 8, child: SizedBox.expand(
      child: FullView(aspectRatio: a, child: Image(image: widget.image, fit: BoxFit.fill, gaplessPlayback: true))));
  }
}
