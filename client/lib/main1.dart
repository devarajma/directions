import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
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

class WebRTCPage extends StatefulWidget {
  const WebRTCPage({super.key});
  @override
  State<WebRTCPage> createState() => _WebRTCPageState();
}

class _WebRTCPageState extends State<WebRTCPage> {
  RTCPeerConnection? _pc;
  MediaStream?       _localStream;
  final _localRenderer = RTCVideoRenderer();
  final _tts           = FlutterTts();

  static const _serverBase = "http://10.211.150.30:8080";
  static const _offerUrl   = "$_serverBase/offer";
  static const _navUrl     = "$_serverBase/nav";

  String  _status      = "Initialising...";
  String  _navMessage  = "";
  bool    _isSafe      = true;
  bool    _ttsEnabled  = true;
  Timer?  _navTimer;
  String  _lastSpoken  = "";
  DateTime _lastSpokenTime = DateTime.now();

  // ── lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _initTts();
    _initRenderer();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.55);   // slightly slower = clearer
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  Future<void> _initRenderer() async {
    await _localRenderer.initialize();
    await _startWebRTC();
  }

  @override
  void dispose() {
    _navTimer?.cancel();
    _tts.stop();
    _localStream?.getTracks().forEach((t) => t.stop());
    _pc?.close();
    _localRenderer.dispose();
    super.dispose();
  }

  // ── nav polling ────────────────────────────────────────────────────────────
  void _startNavPolling() {
    _navTimer?.cancel();
    // poll every 1.5 seconds — matches human speech pacing
    _navTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      try {
        final res = await http
            .get(Uri.parse(_navUrl))
            .timeout(const Duration(seconds: 2));

        if (res.statusCode != 200) return;

        final data    = jsonDecode(res.body) as Map<String, dynamic>;
        final message = data["message"] as String? ?? "";
        final safe    = data["safe"]    as bool?   ?? true;

        setState(() {
          _navMessage = message;
          _isSafe     = safe;
        });

        // speak only if message changed AND enough time has passed
        final now     = DateTime.now();
        final elapsed = now.difference(_lastSpokenTime).inMilliseconds;
        final changed = message != _lastSpoken;

        if (_ttsEnabled && changed && elapsed > 1200) {
          await _tts.stop();
          await _tts.speak(message);
          _lastSpoken     = message;
          _lastSpokenTime = now;
        }
      } catch (_) {
        // server not ready yet — silent fail
      }
    });
  }

  // ── WebRTC setup ───────────────────────────────────────────────────────────
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
          _startNavPolling();   // ← start polling once connected
        }
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _navTimer?.cancel();
        }
      };

      _pc!.onIceConnectionState  = (s) => debugPrint("ICE: ${s.name}");
      _pc!.onIceGatheringState   = (s) => debugPrint("Gathering: ${s.name}");

      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      _setStatus("Creating offer...");
      final offer = await _pc!.createOffer({
        'offerToReceiveVideo': false,
        'offerToReceiveAudio': false,
      });
      await _pc!.setLocalDescription(offer);

      _setStatus("Gathering ICE candidates...");
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

      _setStatus("Streaming ✓");

    } catch (e, stack) {
      debugPrint("WebRTC error: $e\n$stack");
      _setStatus("Error: $e");
    }
  }

  Future<void> _waitForIceGathering() async {
    final state = await _pc!.getIceGatheringState();
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) return;

    final completer = Completer<void>();
    _pc!.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        if (!completer.isCompleted) completer.complete();
      }
    };
    await completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => debugPrint("ICE gather timeout"),
    );
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [

          // ── full screen camera preview ─────────────────────────────────
          Positioned.fill(
            child: RTCVideoView(
              _localRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              mirror: false,
            ),
          ),

          // ── top status bar ─────────────────────────────────────────────
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.fromLTRB(16, 44, 16, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _status,
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
                  ),
                  // mute/unmute TTS
                  GestureDetector(
                    onTap: () => setState(() => _ttsEnabled = !_ttsEnabled),
                    child: Icon(
                      _ttsEnabled ? Icons.volume_up : Icons.volume_off,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── bottom navigation panel ────────────────────────────────────
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              color: _isSafe
                  ? Colors.black.withOpacity(0.7)
                  : Colors.red.withOpacity(0.75),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isSafe ? Icons.check_circle : Icons.warning_amber,
                        color: _isSafe ? Colors.greenAccent : Colors.yellowAccent,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        "NAVIGATION",
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _navMessage.isEmpty ? "Waiting for detection..." : _navMessage,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── retry FAB ──────────────────────────────────────────────────
          Positioned(
            bottom: 110,
            right: 16,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.white24,
              onPressed: () {
                _navTimer?.cancel();
                _tts.stop();
                _localStream?.getTracks().forEach((t) => t.stop());
                _pc?.close();
                setState(() {
                  _status     = "Retrying...";
                  _navMessage = "";
                });
                _startWebRTC();
              },
              child: const Icon(Icons.refresh, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

