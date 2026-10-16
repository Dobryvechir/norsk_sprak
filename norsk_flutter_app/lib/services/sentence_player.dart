import 'dart:async';
import 'package:just_audio/just_audio.dart';
import '../models/entities.dart';

class SentencePlayer {
  final AudioPlayer audio = AudioPlayer();
  final List<Sentence> sentences;
  final void Function() changed;
  int index = 0, repeats = 3, iteration = 1;
  bool looping = true;
  bool _seeking = false;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;
  SentencePlayer(this.sentences, this.changed) {
    // Polling alone is not sample-accurate. just_audio's position stream is used
    // here with a small tolerance; native segment extraction is a future option.
    _positionSub = audio.positionStream.listen((pos) => _checkBoundary(pos));
    _stateSub = audio.playerStateStream.listen((_) => changed());
  }
  Sentence get current => sentences[index];
  Future<void> open(String path) async {
    await audio.setFilePath(path);
    if (sentences.isNotEmpty) await audio.seek(Duration(milliseconds: current.startMs));
    changed();
  }
  Future<void> playPause() async {
    if (audio.playing) { await audio.pause(); return; }
    if (sentences.isEmpty) { await audio.play(); return; }
    final p = audio.position.inMilliseconds;
    if (p < current.startMs || p >= current.endMs) await audio.seek(Duration(milliseconds: current.startMs));
    unawaited(audio.play());
  }
  Future<void> _checkBoundary(Duration pos) async {
    if (!looping || sentences.isEmpty || _seeking || !audio.playing) return;
    if (pos.inMilliseconds < current.endMs) return;
    _seeking = true;
    try {
      if (iteration < repeats) { iteration++; }
      else if (index + 1 < sentences.length) { index++; iteration = 1; }
      else { await audio.pause(); await audio.seek(Duration(milliseconds: current.startMs)); changed(); return; }
      await audio.seek(Duration(milliseconds: current.startMs));
      changed();
    } finally { _seeking = false; }
  }
  Future<void> select(int i) async {
    if (i < 0 || i >= sentences.length) return;
    index = i; iteration = 1;
    await audio.seek(Duration(milliseconds: current.startMs));
    changed();
  }
  Future<void> next() => select(index + 1);
  Future<void> previous() => select(index - 1);
  void setRepeats(int value) { repeats = value.clamp(1, 20); iteration = 1; changed(); }
  Future<void> setSpeed(double speed) async { await audio.setSpeed(speed); changed(); }
  Future<void> dispose() async {
    await _positionSub?.cancel(); await _stateSub?.cancel(); await audio.dispose();
  }
}
