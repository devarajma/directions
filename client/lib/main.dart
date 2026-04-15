import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:background_sms/background_sms.dart';

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

// ── audio priority levels ──────────────────────────────────────────────────────
enum AudioPriority { low, normal, high, critical }

// ── pending speech item ────────────────────────────────────────────────────────
class SpeechItem {
  final String        message;
  final AudioPriority priority;
  final DateTime      queuedAt;
  SpeechItem(this.message, this.priority) : queuedAt = DateTime.now();
}

// ── contact model ──────────────────────────────────────────────────────────────

class EmergencyContact {
  final String name;
  final String number;

  EmergencyContact({
    required this.name,
    required this.number,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'number': number,
      };

  factory EmergencyContact.fromJson(Map<String, dynamic> json) =>
      EmergencyContact(
        name: json['name'] as String,
        number: json['number'] as String,
      );
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

  static const _serverBase = "http://192.168.2.229:8080";
  static const _offerUrl   = "$_serverBase/offer";
  static const _navUrl     = "$_serverBase/nav";

  String  _status      = "Initialising...";
  String  _navMessage  = "";
  bool    _isSafe      = true;
  int     _objectCount = 0;
  Timer?  _navTimer;

  // ── emergency contacts ──────────────────────────────────────────────────
  List<EmergencyContact> _contacts = [];
  SharedPreferences?     _prefs;
  String                 _userPhoneNumber = "";

  // ── persistent text controllers (survive setState rebuilds) ─────────────
  final TextEditingController _userPhoneController = TextEditingController();

  // ── fall detection ──────────────────────────────────────────────────────
  StreamSubscription?    _accelSub;
  DateTime               _lastFallAlert = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration  _fallCooldown  = Duration(seconds: 10);
  static const double    _fallThreshold = 15.0;
  bool _fallCountdownActive = false;
  Timer? _fallCountdownTimer;
  int    _fallCountdownSeconds = 5;

  // ── sliding panel ───────────────────────────────────────────────────────
  final DraggableScrollableController _panelController =
      DraggableScrollableController();


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
    await _loadContacts();
    _startFallDetection();
    await _startWebRTC();
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // pause audio when app goes to background
    if (state == AppLifecycleState.paused)   _audio.stop();
    if (state == AppLifecycleState.resumed)  _audio.speakDirect("Navigation resumed");
  }

  // ── contacts persistence ────────────────────────────────────────────────
  Future<void> _loadContacts() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs?.getStringList('emergency_contacts') ?? [];
    final userPhone = _prefs?.getString('user_phone_number') ?? "";
    setState(() {
      _userPhoneNumber = userPhone;
      _contacts = raw
          .map((s) => EmergencyContact.fromJson(
              jsonDecode(s) as Map<String, dynamic>))
          .toList();
    });
    // sync persistent controller with loaded value
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

  // ── fall detection ──────────────────────────────────────────────────────
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
      _fallCountdownActive = true;
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

  // ── emergency alert ─────────────────────────────────────────────────────
  Future<void> _sendEmergencyAlerts() async {
    if (_contacts.isEmpty) {
      _audio.speakDirect(
          "No emergency contacts configured. Please add contacts in the panel.");
      return;
    }

    _audio.speakDirect("Sending emergency alerts now.");
    HapticFeedback.heavyImpact();

    // ── request SMS + phone state permissions at runtime (Android) ────────
    final smsPermission = await Permission.sms.request();
    if (!smsPermission.isGranted) {
      _audio.speakDirect("SMS permission denied. Cannot send alerts.");
      return;
    }
    // Some devices need phone state permission for SMS
    await Permission.phone.request();

    // get real GPS location
    String locationUrl = "https://maps.google.com/?q=0,0";
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 5),
        ),
      );
      locationUrl =
          "https://maps.google.com/?q=${pos.latitude},${pos.longitude}";
    } catch (e) {
      debugPrint("Location error: $e");
      _audio.speakDirect("Could not get precise location. Sending alert anyway.");
    }

    String senderInfo = _userPhoneNumber.isNotEmpty ? " This is $_userPhoneNumber. " : " ";
    final message = "🚨 EMERGENCY:$senderInfo"
                    "I need help! My current location: $locationUrl";

    final recipients = _contacts.map((c) => c.number).toList();

    int sentCount = 0;
    for (String number in recipients) {
      try {
        SmsStatus result = await BackgroundSms.sendMessage(
            phoneNumber: number, message: message);
        if (result == SmsStatus.sent) {
          sentCount++;
        } else {
          debugPrint("SMS to $number status: $result");
        }
      } catch (e) {
        debugPrint("Failed to send background SMS to $number: $e");
      }
    }
    if (sentCount > 0) {
      _audio.speakDirect("Emergency alert sent to $sentCount contacts.");
    } else {
      _audio.speakDirect("Failed to send emergency alerts. Please check SMS permissions.");
    }
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

      // also request location permission early
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
        'iceServers': [],
        'sdpSemantics':        'unified-plan',
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
          // Auto-retry after a brief delay
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) _retry();
          });
        }
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          // Disconnected is often transient — wait before giving up
          debugPrint("WebRTC disconnected — waiting for recovery...");
          Future.delayed(const Duration(seconds: 5), () {
            // If still disconnected after 5s, retry
            if (_pc?.connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
              _navTimer?.cancel();
              _audio.speakDirect("Connection lost. Retrying.");
              if (mounted) _retry();
            }
          });
        }
      };

      _pc!.onIceConnectionState = (s) {
        debugPrint("ICE connection: ${s.name}");
        if (s == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          debugPrint("ICE failed — will trigger connection state change");
        }
      };
      _pc!.onIceGatheringState  = (s) => debugPrint("ICE gathering: ${s.name}");
      _pc!.onIceCandidate = (candidate) {
        debugPrint("ICE candidate: ${candidate.candidate}");
      };

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
      const Duration(seconds: 15),
      onTimeout: () => debugPrint("ICE gathering timeout — sending SDP with available candidates"),
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

  // ── add contact dialog ──────────────────────────────────────────────────
  void _showAddContactDialog() {
    final nameController   = TextEditingController();
    final numberController = TextEditingController();
    

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            "Add Emergency Contact",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: "Name",
                  labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                  prefixIcon:
                      const Icon(Icons.person, color: Colors.orangeAccent),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.orangeAccent),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: numberController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: "Phone Number",
                  labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                  prefixIcon:
                      const Icon(Icons.phone, color: Colors.orangeAccent),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.orangeAccent),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text("Cancel",
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orangeAccent,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                final name   = nameController.text.trim();
                final number = numberController.text.trim();
                if (name.isNotEmpty && number.isNotEmpty) {
                  _addContact(EmergencyContact(
                    name: name,
                    number: number,
                  ));
                  Navigator.pop(ctx);
                }
              },
              child: const Text("Add",
                  style: TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // DraggableScrollableSheet must be a direct child of Stack, NOT inside
      // a GestureDetector — otherwise the GestureDetector consumes all touches.
      body: Stack(
          children: [

            // ── full screen camera ──────────────────────────────────────
            Positioned.fill(
              child: RTCVideoView(
                _localRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                mirror: false,
              ),
            ),

            // ── top status bar ──────────────────────────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.8),
                      Colors.transparent,
                    ],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 52, 16, 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // status pill — Flexible prevents right overflow on long strings
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.15)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
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
                                    color: Colors.white.withValues(alpha: 0.8),
                                    fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Row(children: [
                      if (_objectCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: _isSafe
                                ? Colors.green.withValues(alpha: 0.25)
                                : Colors.red.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _isSafe
                                  ? Colors.greenAccent.withValues(alpha: 0.4)
                                  : Colors.redAccent.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            "$_objectCount object${_objectCount != 1 ? 's' : ''}",
                            style: const TextStyle(
                                color: Colors.white, fontSize: 11),
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
                            color: Colors.white.withValues(alpha: 0.1),
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

            // ── compact nav info bar ────────────────────────────────────
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      _isSafe
                          ? Colors.black.withValues(alpha: 0.85)
                          : Colors.red.shade900.withValues(alpha: 0.9),
                      Colors.transparent,
                    ],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // safety indicator
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

            // ── fall countdown overlay ──────────────────────────────────
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
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            "Sending alert in $_fallCountdownSeconds s",
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 24),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(
                                  color: Colors.white, width: 2),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 32, vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30)),
                            ),
                            onPressed: _cancelFallCountdown,
                            icon: const Icon(Icons.close, color: Colors.white),
                            label: const Text("TAP TO CANCEL",
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // ── camera-area gesture detector (excludes panel) ──────────
            // Positioned to only cover the camera area above the panel peek
            Positioned(
              top: 0, left: 0, right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onDoubleTap: () => _audio.speakDirect(
                    _navMessage.isEmpty ? "No message yet" : _navMessage),
                onLongPress: () {
                  _audio.toggle();
                  HapticFeedback.heavyImpact();
                  _audio.speakDirect(
                      _audio.enabled ? "Audio on" : "Audio off");
                  setState(() {});
                },
              ),
            ),

            // ── retry + emergency open buttons ──────────────────────────
            Positioned(
              top: 108, right: 12,
              child: Column(
                children: [
                  GestureDetector(
                    onTap: _retry,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.1),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.15)),
                      ),
                      child: const Icon(Icons.refresh,
                          color: Colors.white, size: 20),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Emergency panel open button
                  GestureDetector(
                    onTap: () {
                      _panelController.animateTo(
                        0.5,
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeOut,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.red.withValues(alpha: 0.25),
                        border: Border.all(
                            color: Colors.redAccent.withValues(alpha: 0.5)),
                      ),
                      child: const Icon(Icons.sos_rounded,
                          color: Colors.redAccent, size: 20),
                    ),
                  ),
                ],
              ),
            ),

            // ── sliding emergency panel ─────────────────────────────────
            // Must be OUTSIDE GestureDetector so drags reach it directly.
            DraggableScrollableSheet(
              controller: _panelController,
              initialChildSize: 0.07,
              minChildSize: 0.07,
              maxChildSize: 0.90,
              snap: true,
              snapSizes: const [0.07, 0.50, 0.90],
              builder: (context, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: const Color(0xF51A1A2E),
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(24)),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 30,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: ListView(
                    controller: scrollController,
                    padding: EdgeInsets.zero,
                    children: [
                      // ── drag handle + peek label ──────────────────────
                      GestureDetector(
                        onTap: () {
                          final current = _panelController.size;
                          if (current <= 0.1) {
                            _panelController.animateTo(
                              0.5,
                              duration: const Duration(milliseconds: 350),
                              curve: Curves.easeOut,
                            );
                          } else {
                            _panelController.animateTo(
                              0.07,
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeIn,
                            );
                          }
                        },
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
                          child: Column(
                            children: [
                              Center(
                                child: Container(
                                  width: 40,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.35),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.keyboard_arrow_up,
                                      color: Colors.white.withValues(alpha: 0.4),
                                      size: 16),
                                  const SizedBox(width: 4),
                                  Text(
                                    "Emergency Panel",
                                    style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.4),
                                        fontSize: 11,
                                        letterSpacing: 0.5),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),

                      // ── panel title ───────────────────────────────────
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          "Emergency Panel",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          "Manage contacts & send emergency alerts",
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 13),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // ── My Phone Number ───────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: TextField(
                          controller: _userPhoneController,
                          onChanged: _saveUserPhone,
                          style: const TextStyle(color: Colors.white),
                          keyboardType: TextInputType.phone,
                          decoration: InputDecoration(
                            labelText: "My Phone Number",
                            labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                            prefixIcon: const Icon(Icons.smartphone, color: Colors.orangeAccent),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Colors.orangeAccent),
                            ),
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 20),

                      // ── SEND HELP button ──────────────────────────────
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: _sendEmergencyAlerts,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.red.shade700,
                                    Colors.red.shade900,
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.red.withValues(alpha: 0.4),
                                    blurRadius: 20,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.sos_rounded,
                                      color: Colors.white, size: 28),
                                  SizedBox(width: 10),
                                  Text(
                                    "SEND HELP",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),

                      // ── contacts header ───────────────────────────────
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              "Emergency Contacts",
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            GestureDetector(
                              onTap: _showAddContactDialog,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 7),
                                decoration: BoxDecoration(
                                  color: Colors.orangeAccent.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                      color: Colors.orangeAccent
                                          .withValues(alpha: 0.4)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.person_add,
                                        color: Colors.orangeAccent, size: 16),
                                    SizedBox(width: 6),
                                    Text("Add",
                                        style: TextStyle(
                                            color: Colors.orangeAccent,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // ── contacts list ─────────────────────────────────
                      if (_contacts.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 20),
                          child: Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08)),
                            ),
                            child: Column(
                              children: [
                                Icon(Icons.people_outline,
                                    color: Colors.white.withValues(alpha: 0.2),
                                    size: 40),
                                const SizedBox(height: 10),
                                Text(
                                  "No emergency contacts yet",
                                  style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.4),
                                      fontSize: 14),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "Tap 'Add' to add your first contact",
                                  style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.25),
                                      fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        ...List.generate(_contacts.length, (i) {
                          final c = _contacts[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 4),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.08)),
                              ),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 4),
                                leading: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.greenAccent.withValues(alpha: 0.15),
                                    shape: BoxShape.circle,
                                  ),
                                  child:
                                      const Icon(Icons.sms, color: Colors.greenAccent, size: 20),
                                ),
                                title: Text(c.name,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15)),
                                subtitle: Text(c.number,
                                    style: TextStyle(
                                        color:
                                            Colors.white.withValues(alpha: 0.5),
                                        fontSize: 12)),
                                trailing: GestureDetector(
                                  onTap: () => _removeContact(i),
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withValues(alpha: 0.1),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.delete_outline,
                                        color: Colors.redAccent, size: 18),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),

                      const SizedBox(height: 24),

                      // ── info section ──────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: Colors.blue.withValues(alpha: 0.12)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline,
                                  color: Colors.lightBlueAccent.withValues(alpha: 0.7),
                                  size: 20),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  "Fall detection is active. If a fall is detected, alerts will be sent after a 5-second countdown.",
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 30),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
    );
  }
}