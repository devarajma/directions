import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';

import 'groq_llm_service.dart';
import 'scene_analysis_server.dart';
import 'audio_engine.dart';
import '../controllers/scene_analysis_controller.dart';
export '../controllers/scene_analysis_controller.dart'
    show DoubleTapHoldGestureDetector, AnalysisState, SceneAnalysisController;


/// Complete scene analysis workflow triggered by double-tap-hold gesture.
///
/// Flow:
///   1. Gesture detected → haptic + "Analysing surroundings" spoken
///   2. GET /scene  →  YOLO detections + Depth Anything V2 distances
///   3. Top 3 objects formatted for LLM
///   4. Groq LLaMA-3 generates natural language description
///   5. Description spoken aloud via AudioEngine
///   6. Controller returns to idle
class GestureSceneAnalyzer {
  final AudioEngine              audio;
  final AudioPlayer              audioPlayer;
  final SceneAnalysisController  controller;
  final SceneAnalysisServerClient serverClient;
  final String                   groqApiKey;

  bool   _isProcessing = false;
  Timer? _analysisTimeout;

  static const Duration _totalTimeout  = Duration(seconds: 15);
  static const Duration _sceneFetch    = Duration(seconds: 8);
  static const int      _maxLLMObjects = 5;   // send top 5 to LLM

  GestureSceneAnalyzer({
    required this.audio,
    required this.audioPlayer,
    required this.controller,
    required this.serverClient,
    required this.groqApiKey,
  });

  // ── public entry point ────────────────────────────────────────────────────

  /// Called by DoubleTapHoldGestureDetector when hold completes.
  Future<void> onGestureDetected() async {
    if (_isProcessing) {
      await audio.speakDirect("Already analysing, please wait");
      return;
    }
    if (!controller.canAnalyze()) {
      await audio.speakDirect("Please wait a moment");
      return;
    }
    await _run();
  }

  // ── main workflow ─────────────────────────────────────────────────────────

  Future<void> _run() async {
    final sw = Stopwatch()..start();
    _isProcessing = true;
    controller.startAnalysis();

    // Set a hard ceiling — if anything hangs we bail cleanly
    _analysisTimeout = Timer(_totalTimeout, () {
      if (_isProcessing) {
        _isProcessing = false;
        controller.setError("Timed out");
        audio.speakDirect("Analysis timed out");
      }
    });

    try {
      // ── Step 1: Acknowledge gesture ──────────────────────────────────────
      await _step1_confirm();
      if (_cancelled) return;
      controller.updateProgress(10);

      // ── Step 2: Fetch YOLO + depth from /scene ───────────────────────────
      final scene = await _step2_fetchScene();
      controller.updateProgress(35);

      if (scene == null) {
        await audio.speakDirect("Could not reach the camera server");
        return;
      }

      if (scene.alerts.isEmpty) {
        await audio.speakDirect("Path clear. No objects detected.");
        controller.completeAnalysis(status: "Clear");
        return;
      }

      // ── Step 3: Format for LLM ───────────────────────────────────────────
      final sceneLines = _step3_format(scene);
      controller.updateProgress(50);
      print("🎯 Scene lines for LLM:\n  ${sceneLines.join('\n  ')}");

      if (_cancelled) return;

      // ── Step 4: Groq LLaMA-3 ────────────────────────────────────────────
      controller.updateProgress(55);
      final description = await _step4_llm(sceneLines);
      controller.updateProgress(90);

      if (_cancelled) return;

      // ── Step 5: Speak ────────────────────────────────────────────────────
      await _step5_speak(description);
      controller.completeAnalysis(status: "Done");
      controller.updateProgress(100);

    } catch (e, st) {
      print("❌ GestureSceneAnalyzer error: $e\n$st");
      if (!_cancelled) {
        await audio.speakDirect("Analysis failed. Please try again.");
        controller.setError(e.toString());
      }
    } finally {
      _analysisTimeout?.cancel();
      _isProcessing = false;
      await Future.delayed(const Duration(milliseconds: 600));
      controller.returnToNavigation();
      print("✅ Scene analysis done in ${sw.elapsedMilliseconds}ms");
    }
  }

  // ── steps ─────────────────────────────────────────────────────────────────

  Future<void> _step1_confirm() async {
    // Try to play beep; silently skip if asset missing
    try {
      await audioPlayer.play(AssetSource('sounds/beep.wav'));
    } catch (_) {}
    // Stop ongoing nav speech so we are heard clearly
    await audio.stop();
    await audio.speakDirect("Analysing surroundings");
  }

  Future<SceneSnapshot?> _step2_fetchScene() async {
    try {
      return await serverClient.fetchLatestScene(
        frameWidth:  640,
        frameHeight: 480,
        timeout:     _sceneFetch,
      );
    } catch (e) {
      print("❌ Scene fetch error: $e");
      return null;
    }
  }
  

  List<String> _step3_format(SceneSnapshot scene) {
    // Sort by depth descending (1.0 = closest)
    final sorted = List.of(scene.alerts)
      ..sort((a, b) => b.depth.compareTo(a.depth));

    return sorted
        .take(_maxLLMObjects)
        .map((det) {
          // final dir = det.zone == "center" ? "straight ahead"
          //           : det.zone == "left"   ? "on your left"
          //           : "on your right";
          final zone = det.getZone(640); // 👈 use your frame width

          final dir = zone == "center" ? "straight ahead"
                    : zone == "left"   ? "on your left"
                    : "on your right";
          final dist = det.distanceEstimate.isNotEmpty
              ? det.distanceEstimate
              : _proximityToWords(det.depthProximity);
          return "${det.label}, $dist, $dir";
        })
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<String> _step4_llm(List<String> lines) async {
    try {
      final result = await GroqLLMService.analyzeScene(
        sceneObjects: lines,
        apiKey:       groqApiKey,
      );
      if (result.isEmpty) return _fallback(lines);
      return result;
    } catch (e) {
      print("❌ LLM error: $e");
      return _fallback(lines);
    }
  }

  Future<void> _step5_speak(String text) async {
    // Stop any nav audio still playing
    await audio.stop();
    await audio.speakDirect(text);
    // Wait long enough for TTS to finish before returning to nav
    final estimatedMs = (text.length * 60).clamp(1500, 12000);
    await Future.delayed(Duration(milliseconds: estimatedMs));
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  bool get _cancelled => controller.state == AnalysisState.cancelled;

  /// Fallback when LLM fails — build description from detections directly
  String _fallback(List<String> lines) {
    if (lines.isEmpty) return "No objects detected.";
    if (lines.length == 1) return lines.first;
    return "${lines.first}. Also: ${lines.skip(1).join(', ')}.";
  }

  String _proximityToWords(String prox) {
    switch (prox) {
      case "close":  return "very close";
      case "medium": return "a few metres away";
      default:       return "far away";
    }
  }

  void dispose() {
    _analysisTimeout?.cancel();
  }
}

// ── Re-export so main.dart import stays the same ──────────────────────────────
// export '../controllers/scene_analysis_controller.dart'
//     show DoubleTapHoldGestureDetector, AnalysisState, SceneAnalysisController;

/// Scene analysis overlay widget — drop into your Stack directly.
///
/// Usage inside your Stack:
///   SceneAnalysisOverlay(controller: _sceneAnalysisController)
class SceneAnalysisOverlay extends StatelessWidget {
  final SceneAnalysisController controller;
  const SceneAnalysisOverlay({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.state == AnalysisState.idle) {
          return const SizedBox.shrink();
        }

        final isAnalysing = controller.state == AnalysisState.analyzing;
        final isSpeaking  = controller.state == AnalysisState.speaking;
        final progress    = controller.analyzeProgress / 100.0;

        return Positioned.fill(
          child: Container(
            color: Colors.black.withValues(alpha: 0.55),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [

                  // ── animated ring ──────────────────────────────────────
                  SizedBox(
                    width: 80,
                    height: 80,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: isAnalysing ? null : progress,
                          strokeWidth: 4,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isSpeaking
                                ? Colors.greenAccent
                                : Colors.orangeAccent,
                          ),
                        ),
                        Icon(
                          isSpeaking
                              ? Icons.spatial_audio_off_rounded
                              : Icons.radar_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── status text ────────────────────────────────────────
                  Text(
                    controller.status.isNotEmpty
                        ? controller.status
                        : (isAnalysing ? "Analysing…" : "Speaking…"),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  if (!isAnalysing) ...[
                    const SizedBox(height: 6),
                    Text(
                      "${(progress * 100).toInt()}%",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 11,
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // ── hint ───────────────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      "Hold to cancel",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}