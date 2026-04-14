import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(home: WebRTCPage());
}

// ── audio priority levels ──────────────────────────────────────────────────────
enum AudioPriority { low, normal, high, critical }

// ── pending speech item ────────────────────────────────────────────────────────
class SpeechItem {
  final String        message;
  final AudioPriority priority;
  final DateTime      queuedAt;
  SpeechItem(this.message, this.priority) : queuedAt = DateTime.now();
}

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


// ── main page ──────────────────────────────────────────────────────────────────
class WebRTCPage extends StatefulWidget {
  const WebRTCPage({super.key});
  @override
  State<WebRTCPage> createState() => _WebRTCPageState();
}

class _WebRTCPageState extends State<WebRTCPage> with WidgetsBindingObserver {
  RTCPeerConnection? _pc;
  MediaStream?       _localStream;
  final _localRenderer = RTCVideoRenderer();
  final _audio         = AudioEngine();

  static const _serverBase = "http://10.211.150.30:8080";
  static const _offerUrl   = "$_serverBase/offer";
  static const _navUrl     = "$_serverBase/nav";

  String  _status     = "Initialising...";
  String  _navMessage = "";
  bool    _isSafe     = true;
  int     _objectCount = 0;
  Timer?  _navTimer;

  // ── lifecycle ────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _audio.init();
    await _localRenderer.initialize();
    await _startWebRTC();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _navTimer?.cancel();
    _audio.dispose();
    _localStream?.getTracks().forEach((t) => t.stop());
    _pc?.close();
    _localRenderer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // pause audio when app goes to background
    if (state == AppLifecycleState.paused)   _audio.stop();
    if (state == AppLifecycleState.resumed)  _audio.speakDirect("Navigation resumed");
  }

  // ── nav polling ──────────────────────────────────────────────────────────
  void _startNavPolling() {
  _navTimer?.cancel();
  _navTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) async {
    try {
      final res = await http
          .get(Uri.parse(_navUrl))
          .timeout(const Duration(seconds: 2));
      if (res.statusCode != 200) return;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final msg  = data["message"] as String? ?? "";
      final safe = data["safe"]    as bool?   ?? true;
      final n    = (data["alerts"] as List?)?.length ?? 0;

      setState(() {
        _navMessage  = msg;
        _isSafe      = safe;
        _objectCount = n;
      });

      await _audio.process(data);
    } catch (_) {}
  });
}

  // ── WebRTC setup ─────────────────────────────────────────────────────────
  Future<void> _startWebRTC() async {
    try {
      _setStatus("Requesting permissions...");
      final cam = await Permission.camera.request();
      if (!cam.isGranted) { _setStatus("Camera permission denied"); return; }

      _setStatus("Opening camera...");
      _localStream = await navigator.mediaDevices.getUserMedia({
        'video': {
          'facingMode': 'environment',
          'width':     {'ideal': 640},
          'height':    {'ideal': 480},
          'frameRate': {'ideal': 30},
        },
        'audio': false,
      });
      setState(() => _localRenderer.srcObject = _localStream);

      _pc = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
          {'urls': 'stun:stun2.l.google.com:19302'},
        ],
        'sdpSemantics':        'unified-plan',
        'iceCandidatePoolSize': 10,
      });

      _pc!.onConnectionState = (state) {
        _setStatus("Connection: ${state.name}");
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _startNavPolling();
          _audio.speakDirect("Navigation started");
        }
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _navTimer?.cancel();
          _audio.speakDirect("Connection lost");
        }
      };

      _pc!.onIceConnectionState = (s) => debugPrint("ICE: ${s.name}");
      _pc!.onIceGatheringState  = (s) => debugPrint("Gathering: ${s.name}");

      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      _setStatus("Creating offer...");
      final offer = await _pc!.createOffer({
        'offerToReceiveVideo': false,
        'offerToReceiveAudio': false,
      });
      await _pc!.setLocalDescription(offer);

      _setStatus("Gathering ICE...");
      await _waitForIceGathering();

      final localDesc = await _pc!.getLocalDescription();
      if (localDesc == null) { _setStatus("No local description"); return; }

      _setStatus("Connecting to server...");
      final response = await http.post(
        Uri.parse(_offerUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({"sdp": localDesc.sdp, "type": localDesc.type}),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        _setStatus("Server error: ${response.statusCode}");
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      await _pc!.setRemoteDescription(
        RTCSessionDescription(data["sdp"] as String, data["type"] as String),
      );
      _setStatus("Streaming");

    } catch (e, stack) {
      debugPrint("WebRTC error: $e\n$stack");
      _setStatus("Error: $e");
    }
  }

  Future<void> _waitForIceGathering() async {
    final state = await _pc!.getIceGatheringState();
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) return;
    final c = Completer<void>();
    _pc!.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        if (!c.isCompleted) c.complete();
      }
    };
    await c.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => debugPrint("ICE timeout"),
    );
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  // ── retry ────────────────────────────────────────────────────────────────
  void _retry() {
    _navTimer?.cancel();
    _audio.stop();
    _localStream?.getTracks().forEach((t) => t.stop());
    _pc?.close();
    setState(() { _status = "Retrying..."; _navMessage = ""; });
    _startWebRTC();
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // double-tap → repeat last message
        onDoubleTap: () => _audio.speakDirect(_navMessage.isEmpty
            ? "No message yet"
            : _navMessage),
        // long press → toggle audio
        onLongPress: () {
          _audio.toggle();
          HapticFeedback.heavyImpact();
          _audio.speakDirect(
              _audio.enabled ? "Audio on" : "Audio off");
          setState(() {});
        },
        child: Stack(
          children: [

            // full screen camera
            Positioned.fill(
              child: RTCVideoView(
                _localRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                mirror: false,
              ),
            ),

            // top bar
            Positioned(
              top: 0, left: 0, right: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.fromLTRB(16, 48, 16, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_status,
                        style: const TextStyle(
                            color: Colors.greenAccent, fontSize: 12)),
                    Row(children: [
                      if (_objectCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _isSafe
                                ? Colors.green.withOpacity(0.7)
                                : Colors.red.withOpacity(0.8),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            "$_objectCount object${_objectCount != 1 ? 's' : ''}",
                            style: const TextStyle(
                                color: Colors.white, fontSize: 11),
                          ),
                        ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: () {
                          _audio.toggle();
                          setState(() {});
                        },
                        child: Icon(
                          _audio.enabled
                              ? Icons.volume_up
                              : Icons.volume_off,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ),

            // navigation panel
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                color: _isSafe
                    ? Colors.black.withOpacity(0.72)
                    : Colors.red.shade900.withOpacity(0.85),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      Icon(
                        _isSafe
                            ? Icons.check_circle_outline
                            : Icons.warning_amber_rounded,
                        color: _isSafe
                            ? Colors.greenAccent
                            : Colors.yellowAccent,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _isSafe ? "CLEAR" : "DANGER",
                        style: TextStyle(
                          color: _isSafe
                              ? Colors.greenAccent
                              : Colors.yellowAccent,
                          fontSize: 10,
                          letterSpacing: 1.8,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                      _navMessage.isEmpty
                          ? "Waiting for detection..."
                          : _navMessage,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          height: 1.4),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Double-tap to repeat  ·  Long-press to mute",
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),

            // retry button
            Positioned(
              bottom: 120, right: 16,
              child: FloatingActionButton.small(
                backgroundColor: Colors.white24,
                onPressed: _retry,
                child: const Icon(Icons.refresh, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}