import 'package:flutter_tts/flutter_tts.dart';

// ── audio engine v3 ────────────────────────────────────────────────────────────
class AudioEngine {
  final FlutterTts _tts = FlutterTts();
  bool _enabled         = true;
  bool _speaking        = false;

  String   _lastSpoken     = "";
  DateTime _lastSpokenAt   = DateTime.fromMillisecondsSinceEpoch(0);

  // per-label last-spoken time
  final Map<String, DateTime> _labelLastSpoken = {};

  // how long to wait before repeating the SAME label
  static const Duration _labelCooldown  = Duration(seconds: 4);
  // minimum gap between any two speech outputs
  static const Duration _globalCooldown = Duration(milliseconds: 2500);
  // danger objects get a shorter repeat gap
  static const Duration _dangerCooldown = Duration(seconds: 2);

  Future<void> init() async {
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.50);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _tts.setCompletionHandler(() => _speaking = false);
    _tts.setErrorHandler((_)    => _speaking = false);
  }

  bool get enabled => _enabled;
  void toggle()    => _enabled = !_enabled;

  Future<void> process(Map<String, dynamic> nav) async {
    if (!_enabled) return;

    final safe   = nav["safe"]   as bool?  ?? true;
    final alerts = (nav["alerts"] as List?)
            ?.cast<Map<String, dynamic>>() ?? [];

    // ── FILTER 1: drop far objects entirely ──────────────────────────────────
    final relevant = alerts.where((a) {
      final prox = a["proximity"] as String? ?? "far";
      return prox != "far";                         // only close + medium
    }).toList();

    // ── FILTER 2: drop receding objects ──────────────────────────────────────
    final actionable = relevant.where((a) {
      final approach = a["approach"] as String? ?? "stable";
      return approach != "receding";                // drop moving-away objects
    }).toList();

    // ── FILTER 3: if path is clear → single calm message then silence ─────────
    if (actionable.isEmpty) {
      final now     = DateTime.now();
      final elapsed = now.difference(_lastSpokenAt);
      // only say "path clear" once every 6 seconds max, and only
      // if we WERE saying something before (transition to clear)
      if (_lastSpoken != "Path clear" && elapsed > const Duration(seconds: 6)) {
        await _speakNow("Path clear", critical: false);
      }
      return;
    }

    // ── FILTER 4: sort by urgency ─────────────────────────────────────────────
    // priority: danger > close > approaching > center-zone
    actionable.sort((a, b) {
      int score(Map<String, dynamic> x) {
        int s = 0;
        if (x["danger"]    == true)          s += 100;
        if (x["proximity"] == "close")       s += 50;
        if (x["approach"]  == "approaching") s += 30;
        if (x["zone"]      == "center")      s += 20;
        return s;
      }
      return score(b).compareTo(score(a));
    });

    // ── FILTER 5: pick only top 2 objects worth speaking about ───────────────
    final now       = DateTime.now();
    final toSpeak   = <Map<String, dynamic>>[];

    for (final a in actionable) {
      if (toSpeak.length >= 2) break;

      final label     = a["label"]    as String? ?? "object";
      final isDanger  = a["danger"]   as bool?   ?? false;
      final cooldown  = isDanger ? _dangerCooldown : _labelCooldown;
      final lastSeen  = _labelLastSpoken[label];

      // skip if this label was spoken recently
      if (lastSeen != null && now.difference(lastSeen) < cooldown) continue;

      toSpeak.add(a);
      _labelLastSpoken[label] = now;
    }

    if (toSpeak.isEmpty) return;

    // ── FILTER 6: global gap — don't interrupt current speech ─────────────────
    final globalElapsed = now.difference(_lastSpokenAt);
    final isCritical    = toSpeak.any((a) =>
        a["danger"]    == true &&
        a["proximity"] == "close" &&
        a["approach"]  == "approaching");

    if (_speaking && !isCritical) return;
    if (!isCritical && globalElapsed < _globalCooldown) return;

    // ── BUILD message ─────────────────────────────────────────────────────────
    final message = _buildMessage(toSpeak, safe);
    if (message == _lastSpoken && globalElapsed < const Duration(seconds: 5)) return;

    if (isCritical && _speaking) {
      await _tts.stop();
      _speaking = false;
    }

    await _speakNow(message, critical: isCritical);
  }

  String _buildMessage(List<Map<String, dynamic>> items, bool safe) {
    final parts = <String>[];

    for (final a in items) {
      final label    = a["label"]    as String? ?? "object";
      final zone     = a["zone"]     as String? ?? "center";
      final prox     = a["proximity"] as String? ?? "medium";
      final approach = a["approach"] as String? ?? "stable";
      final danger   = a["danger"]   as bool?   ?? false;

      final buf = StringBuffer();

      // danger prefix only for close danger
      if (danger && prox == "close") buf.write("Warning. ");

      buf.write(label.toLowerCase());

      // zone → navigation instruction
      switch (zone) {
        case "left":   buf.write(" on your left");   break;
        case "right":  buf.write(" on your right");  break;
        case "center": buf.write(" straight ahead"); break;
      }

      // proximity — only mention if close
      if (prox == "close") buf.write(", very close");

      // approach — only mention if approaching
      if (approach == "approaching") buf.write(", moving toward you");

      parts.add(buf.toString());
    }

    // join two items naturally
    return parts.length == 1
        ? parts[0]
        : "${parts[0]}. ${parts[1]}";
  }

  Future<void> _speakNow(String message, {required bool critical}) async {
    _speaking     = true;
    _lastSpoken   = message;
    _lastSpokenAt = DateTime.now();
    await _tts.speak(message);
  }

  Future<void> speakDirect(String message) async {
    await _tts.stop();
    _speaking = false;
    _speaking     = true;
    _lastSpoken   = message;
    _lastSpokenAt = DateTime.now();
    await _tts.speak(message);
  }

  Future<void> stop() async {
    await _tts.stop();
    _speaking = false;
  }

  void dispose() => _tts.stop();
}
