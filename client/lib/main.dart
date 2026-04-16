import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_sms/flutter_sms.dart';
import 'package:audioplayers/audioplayers.dart';

import 'emergency_panel.dart';
import 'models/emergency_contact.dart';
import 'services/audio_engine.dart';
import 'services/emergency_service.dart';
import 'controllers/scene_analysis_controller.dart';
import 'services/scene_analysis_server.dart';
import 'services/gesture_scene_analyzer.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Navigation Assistant',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.dark(
            primary: Colors.redAccent.shade200,
            secondary: Colors.orangeAccent,
          ),
        ),
        home: const WebRTCPage(),
      );
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

  static const _serverBase = "http://192.168.2.229:8080";
  static const _offerUrl   = "$_serverBase/offer";
  static const _navUrl     = "$_serverBase/nav";

  String  _status      = "Initialising...";
  String  _navMessage  = "";
  bool    _isSafe      = true;
  int     _objectCount = 0;
  Timer?  _navTimer;

  // ── Scene Analysis ─────────────────────────────────────────────────────────
  late SceneAnalysisController      _sceneAnalysisController;
  late DoubleTapHoldGestureDetector _gestureDetector;
  late GestureSceneAnalyzer         _gestureAnalyzer;
  late SceneAnalysisServerClient    _sceneServerClient;
  final AudioPlayer _analysisAudioPlayer = AudioPlayer();

  // Groq API key — move to flutter_secure_storage before production
  static const String _groqApiKey =
      "";

  // ── emergency contacts ─────────────────────────────────────────────────────
  List<EmergencyContact> _contacts        = [];
  SharedPreferences?     _prefs;
  String                 _userPhoneNumber = "";
  final TextEditingController _userPhoneController = TextEditingController();

  // ── fall detection ─────────────────────────────────────────────────────────
  StreamSubscription?   _accelSub;
  DateTime              _lastFallAlert       = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _fallCooldown        = Duration(seconds: 10);
  static const double   _fallThreshold       = 15.0;
  bool   _fallCountdownActive  = false;
  Timer? _fallCountdownTimer;
  int    _fallCountdownSeconds = 5;

  // ── sliding panel ──────────────────────────────────────────────────────────
  final DraggableScrollableController _panelController =
      DraggableScrollableController();

  // ══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSceneAnalysis();
    _init();
  }

  Future<void> _init() async {
    await _audio.init();
    await _localRenderer.initialize();
    await _loadContacts();
    await _initializeEmergencyService();
    _startFallDetection();
    await _startWebRTC();
  }

  // ── Scene Analysis init ────────────────────────────────────────────────────
  void _initSceneAnalysis() {
    _sceneAnalysisController = SceneAnalysisController();

    _sceneServerClient = SceneAnalysisServerClient(
      serverUrl: _serverBase,
    );

    // GestureSceneAnalyzer — no longer takes a FlutterTts arg
    _gestureAnalyzer = GestureSceneAnalyzer(
      audio:        _audio,
      audioPlayer:  _analysisAudioPlayer,
      controller:   _sceneAnalysisController,
      serverClient: _sceneServerClient,
      groqApiKey:   _groqApiKey,
    );

    _gestureDetector = DoubleTapHoldGestureDetector(
      // ── double-tap (quick release < 300 ms) → repeat last message ────────
      onDoubleTap: () {
        final last = _audio.lastSpoken;
        if (last.isNotEmpty) {
          _audio.speakDirect(last);
        }
      },
      // ── second tap starts, hold timer running ─────────────────────────────
      onGestureStart: () {
        // subtle haptic so the user knows the hold phase has begun
        HapticFeedback.lightImpact();
      },
      // ── hold completed (600 ms) → full scene analysis ─────────────────────
      onGestureDetected: () {
        HapticFeedback.mediumImpact();
        _gestureAnalyzer.onGestureDetected();
      },
      // ── released early → silent cancel ───────────────────────────────────
      onGestureCancelled: () {
        _sceneAnalysisController.cancel();
      },
    );

    print("✅ Scene analysis initialised");
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _navTimer?.cancel();
    _fallCountdownTimer?.cancel();
    _accelSub?.cancel();
    _audio.dispose();
    _localStream?.getTracks().forEach((t) => t.stop());
    _pc?.close();
    _localRenderer.dispose();
    _panelController.dispose();
    _userPhoneController.dispose();
    _gestureDetector.dispose();
    _gestureAnalyzer.dispose();
    _sceneAnalysisController.dispose();
    _analysisAudioPlayer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused)  _audio.stop();
    if (state == AppLifecycleState.resumed) _audio.speakDirect("Navigation resumed");
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CONTACTS
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _loadContacts() async {
    _prefs = await SharedPreferences.getInstance();
    final raw       = _prefs?.getStringList('emergency_contacts') ?? [];
    final userPhone = _prefs?.getString('user_phone_number') ?? "";
    setState(() {
      _userPhoneNumber = userPhone;
      _contacts = raw
          .map((s) => EmergencyContact.fromJson(
              jsonDecode(s) as Map<String, dynamic>))
          .toList();
    });
    _userPhoneController.text = _userPhoneNumber;
  }

  Future<void> _saveContacts() async {
    final raw = _contacts.map((c) => jsonEncode(c.toJson())).toList();
    await _prefs?.setStringList('emergency_contacts', raw);
  }

  Future<void> _saveUserPhone(String num) async {
    setState(() => _userPhoneNumber = num);
    await _prefs?.setString('user_phone_number', num);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // EMERGENCY SERVICE
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _initializeEmergencyService() async {
    try {
      final granted = await EmergencyService.requestPermissions();
      if (!granted) {
        _showSnackBar('Some permissions were denied. Emergency alerts may not work.');
      }
    } catch (e) {
      _showSnackBar('Error initializing emergency service: $e');
    }
  }

  void _addContact(EmergencyContact contact) {
    setState(() => _contacts.add(contact));
    _saveContacts();
    _audio.speakDirect("Contact ${contact.name} added");
  }

  void _removeContact(int index) {
    final name = _contacts[index].name;
    setState(() => _contacts.removeAt(index));
    _saveContacts();
    _audio.speakDirect("Contact $name removed");
  }

  void _showSnackBar(String message, {bool isSuccess = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? Colors.green : Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FALL DETECTION
  // ══════════════════════════════════════════════════════════════════════════

  void _startFallDetection() {
    _accelSub = userAccelerometerEventStream().listen((event) {
      if (_detectFall(event)) {
        final now = DateTime.now();
        if (now.difference(_lastFallAlert) > _fallCooldown &&
            !_fallCountdownActive) {
          _lastFallAlert = now;
          _startFallCountdown();
        }
      }
    });
  }

  bool _detectFall(UserAccelerometerEvent event) {
    final magnitude =
        sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    return magnitude > _fallThreshold;
  }

  void _startFallCountdown() {
    setState(() {
      _fallCountdownActive  = true;
      _fallCountdownSeconds = 5;
    });
    _audio.speakDirect(
        "Fall detected. Sending emergency alert in 5 seconds. Tap screen to cancel.");
    HapticFeedback.heavyImpact();

    _fallCountdownTimer?.cancel();
    _fallCountdownTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _fallCountdownSeconds--);
      if (_fallCountdownSeconds <= 0) {
        timer.cancel();
        setState(() => _fallCountdownActive = false);
        _sendEmergencyAlerts();
      }
    });
  }

  void _cancelFallCountdown() {
    _fallCountdownTimer?.cancel();
    setState(() => _fallCountdownActive = false);
    _audio.speakDirect("Emergency alert cancelled.");
    HapticFeedback.mediumImpact();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // EMERGENCY ALERT
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _sendEmergencyAlerts() async {
    if (_contacts.isEmpty) {
      _audio.speakDirect(
          "No emergency contacts configured. Please add contacts in the panel.");
      return;
    }

    _audio.speakDirect("Sending emergency alerts now.");
    HapticFeedback.heavyImpact();

    final canSend = await canSendSMS();
    if (!canSend) {
      _audio.speakDirect("This device cannot send SMS.");
      return;
    }

    String locationUrl = "https://maps.google.com/?q=0,0";
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 5),
        ),
      );
      locationUrl =
          "https://maps.google.com/?q=${pos.latitude},${pos.longitude}";
    } catch (e) {
      debugPrint("Location error (using fallback): $e");
    }

    final senderInfo =
        _userPhoneNumber.isNotEmpty ? " This is $_userPhoneNumber." : "";
    final message =
        "EMERGENCY:$senderInfo I need help! My location: $locationUrl";

    final uniqueNumbers = _contacts
        .map((c) => c.number.replaceAll(RegExp(r'[^\d+]'), ''))
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();

    try {
      await sendSMS(message: message, recipients: uniqueNumbers);
      _audio.speakDirect(
          "Emergency alert sent to ${uniqueNumbers.length} contacts.");
    } catch (e) {
      debugPrint("SMS error: $e");
      _audio.speakDirect("Failed to send emergency alerts.");
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // NAV POLLING
  // ══════════════════════════════════════════════════════════════════════════

  void _startNavPolling() {
    _navTimer?.cancel();
    _navTimer =
        Timer.periodic(const Duration(milliseconds: 1200), (_) async {
      // Pause nav polling while scene analysis overlay is visible
      if (_sceneAnalysisController.state != AnalysisState.idle) return;

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

  // ══════════════════════════════════════════════════════════════════════════
  // WEBRTC
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _startWebRTC() async {
    try {
      _setStatus("Requesting permissions...");
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        _setStatus("Camera permission denied");
        return;
      }
      await Permission.location.request();

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
        'iceServers':           [],
        'sdpSemantics':         'unified-plan',
        'iceCandidatePoolSize': 0,
      });

      _pc!.onConnectionState = (state) {
        debugPrint("WebRTC connection state: ${state.name}");
        _setStatus("Connection: ${state.name}");
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _startNavPolling();
          _audio.speakDirect("Navigation started");
        }
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _navTimer?.cancel();
          _audio.speakDirect("Connection failed. Retrying.");
          Future.delayed(
              const Duration(seconds: 2), () { if (mounted) _retry(); });
        }
        if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          Future.delayed(const Duration(seconds: 5), () {
            if (_pc?.connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
              _navTimer?.cancel();
              _audio.speakDirect("Connection lost. Retrying.");
              if (mounted) _retry();
            }
          });
        }
      };

      _pc!.onIceConnectionState =
          (s) => debugPrint("ICE connection: ${s.name}");
      _pc!.onIceGatheringState =
          (s) => debugPrint("ICE gathering: ${s.name}");
      _pc!.onIceCandidate =
          (c) => debugPrint("ICE candidate: ${c.candidate}");

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
      if (localDesc == null) {
        _setStatus("No local description");
        return;
      }

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
        RTCSessionDescription(
            data["sdp"] as String, data["type"] as String),
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
      const Duration(seconds: 15),
      onTimeout: () => debugPrint("ICE gathering timeout"),
    );
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  void _retry() {
    _navTimer?.cancel();
    _audio.stop();
    _localStream?.getTracks().forEach((t) => t.stop());
    _pc?.close();
    setState(() {
      _status     = "Retrying...";
      _navMessage = "";
    });
    _startWebRTC();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ADD CONTACT DIALOG
  // ══════════════════════════════════════════════════════════════════════════

  void _showAddContactDialog() {
    final nameCtrl   = TextEditingController();
    final numberCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: const Text("Add Emergency Contact",
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _contactField(nameCtrl,   "Name",         Icons.person),
            const SizedBox(height: 14),
            _contactField(numberCtrl, "Phone Number",  Icons.phone,
                keyboard: TextInputType.phone),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Cancel",
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              final name   = nameCtrl.text.trim();
              final number = numberCtrl.text.trim();
              if (name.isNotEmpty && number.isNotEmpty) {
                _addContact(EmergencyContact(name: name, number: number));
                Navigator.pop(ctx);
              }
            },
            child: const Text("Add",
                style: TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _contactField(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    TextInputType keyboard = TextInputType.text,
  }) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white),
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        labelStyle:
            TextStyle(color: Colors.white.withValues(alpha: 0.6)),
        prefixIcon: Icon(icon, color: Colors.orangeAccent),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
              color: Colors.white.withValues(alpha: 0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: Colors.orangeAccent),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Listener — routes all pointer events to gesture detector ────
          Listener(
            onPointerDown: (e) => _gestureDetector.onTapDown(TapDownDetails(
              globalPosition: e.position,
              localPosition:  e.localPosition,
              kind:           e.kind,
            )),
            onPointerUp: (e) => _gestureDetector.onTapUp(TapUpDetails(
              globalPosition: e.position,
              localPosition:  e.localPosition,
              kind:           e.kind,
            )),
            onPointerMove: _gestureDetector.onPointerMove,
            child: Stack(
              children: [

                // ── Full-screen camera ──────────────────────────────────
                Positioned.fill(
                  child: RTCVideoView(
                    _localRenderer,
                    objectFit: RTCVideoViewObjectFit
                        .RTCVideoViewObjectFitCover,
                    mirror: false,
                  ),
                ),

                // ── Top status bar ──────────────────────────────────────
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end:   Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.8),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    padding:
                        const EdgeInsets.fromLTRB(16, 52, 16, 18),
                    child: Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        // status pill
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.white
                                  .withValues(alpha: 0.1),
                              borderRadius:
                                  BorderRadius.circular(20),
                              border: Border.all(
                                  color: Colors.white
                                      .withValues(alpha: 0.15)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 7, height: 7,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _status == "Streaming"
                                        ? Colors.greenAccent
                                        : Colors.orangeAccent,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    _status,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.8),
                                        fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // object count + mute button
                        Row(children: [
                          if (_objectCount > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: _isSafe
                                    ? Colors.green
                                        .withValues(alpha: 0.25)
                                    : Colors.red
                                        .withValues(alpha: 0.35),
                                borderRadius:
                                    BorderRadius.circular(20),
                                border: Border.all(
                                  color: _isSafe
                                      ? Colors.greenAccent
                                          .withValues(alpha: 0.4)
                                      : Colors.redAccent
                                          .withValues(alpha: 0.5),
                                ),
                              ),
                              child: Text(
                                "$_objectCount object"
                                "${_objectCount != 1 ? 's' : ''}",
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11),
                              ),
                            ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () {
                              _audio.toggle();
                              setState(() {});
                            },
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white
                                    .withValues(alpha: 0.1),
                              ),
                              child: Icon(
                                _audio.enabled
                                    ? Icons.volume_up
                                    : Icons.volume_off,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),

                // ── Bottom nav panel ────────────────────────────────────
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end:   Alignment.topCenter,
                        colors: [
                          _isSafe
                              ? Colors.black
                                  .withValues(alpha: 0.85)
                              : Colors.red.shade900
                                  .withValues(alpha: 0.9),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    padding:
                        const EdgeInsets.fromLTRB(16, 24, 16, 8),
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
                            size: 14,
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
                              fontSize: 14,
                              height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Fall countdown overlay ──────────────────────────────
                if (_fallCountdownActive)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _cancelFallCountdown,
                      child: Container(
                        color: Colors.red.withValues(alpha: 0.6),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.warning_amber_rounded,
                                  color: Colors.white, size: 80),
                              const SizedBox(height: 16),
                              const Text(
                                "FALL DETECTED",
                                style: TextStyle(
                                  color:       Colors.white,
                                  fontSize:    28,
                                  fontWeight:  FontWeight.w900,
                                  letterSpacing: 2,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                "Sending alert in"
                                " $_fallCountdownSeconds s",
                                style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 18),
                              ),
                              const SizedBox(height: 24),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(
                                      color: Colors.white, width: 2),
                                  padding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 32,
                                          vertical: 14),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(30)),
                                ),
                                onPressed: _cancelFallCountdown,
                                icon: const Icon(Icons.close,
                                    color: Colors.white),
                                label: const Text("TAP TO CANCEL",
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight:
                                            FontWeight.bold)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // ── Long-press → toggle audio ───────────────────────────
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onLongPress: () {
                      _audio.toggle();
                      HapticFeedback.heavyImpact();
                      _audio.speakDirect(
                          _audio.enabled ? "Audio on" : "Audio off");
                      setState(() {});
                    },
                  ),
                ),

                // ── Right-side buttons ──────────────────────────────────
                Positioned(
                  top: 108, right: 12,
                  child: Column(
                    children: [
                      // Retry
                      _iconButton(
                        icon: Icons.refresh,
                        color: Colors.white,
                        bg: Colors.white.withValues(alpha: 0.1),
                        border:
                            Colors.white.withValues(alpha: 0.15),
                        onTap: _retry,
                      ),
                      const SizedBox(height: 10),

                      // SOS
                      _iconButton(
                        icon: Icons.sos_rounded,
                        color: Colors.redAccent,
                        bg: Colors.red.withValues(alpha: 0.25),
                        border: Colors.redAccent
                            .withValues(alpha: 0.5),
                        onTap: () => _panelController.animateTo(
                          0.5,
                          duration:
                              const Duration(milliseconds: 350),
                          curve: Curves.easeOut,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),

                // ── Sliding emergency panel ─────────────────────────────
                EmergencyPanel(
                  panelController:       _panelController,
                  userPhoneController:   _userPhoneController,
                  onSaveUserPhone:       _saveUserPhone,
                  onSendEmergencyAlerts: _sendEmergencyAlerts,
                  onShowAddContactDialog: _showAddContactDialog,
                  contacts:              _contacts,
                  onRemoveContact:       _removeContact,
                ),

              ],
            ),
          ),

          // ── Scene Analysis Overlay ──────────────────────────────────────
          // Sits OUTSIDE the inner Stack so it always renders on top of
          // the emergency panel and fall overlay.
          SceneAnalysisOverlay(controller: _sceneAnalysisController),

        ],
      ),
    );
  }

  // ── small helper ──────────────────────────────────────────────────────────
  Widget _iconButton({
    required IconData  icon,
    required Color     color,
    required Color     bg,
    required Color     border,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          shape:  BoxShape.circle,
          color:  bg,
          border: Border.all(color: border),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}