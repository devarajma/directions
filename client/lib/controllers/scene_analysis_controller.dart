import 'package:flutter/material.dart';
import 'dart:async';

/// State for scene analysis mode
enum AnalysisState {
  idle,           // Normal navigation
  analyzing,      // Processing scene
  speaking,       // Speaking result
  cancelled,      // User cancelled gesture
}

/// Gesture detector for double-tap + hold (600ms)
///
/// Flow: tap → release → tap again within 400ms → hold for 600ms → detected!
/// If the user releases before 600ms, the gesture is cancelled.
/// Once detected, releasing the finger does NOT cancel.
class DoubleTapHoldGestureDetector {
  DateTime? _firstTapTime;
  DateTime? _secondTapTime;
  bool _isHolding = false;
  bool _gestureCompleted = false; // prevents cancel after successful detection
  Timer? _holdTimer;
  
  // Timing constraints
  static const Duration _doubleTapWindow = Duration(milliseconds: 400);
  static const Duration _holdDuration = Duration(milliseconds: 600);
  
  // Callbacks
  final VoidCallback? onGestureStart;      // When second tap starts
  final VoidCallback? onGestureDetected;   // When hold duration reached
  final VoidCallback? onGestureCancelled;  // When user releases early
  final VoidCallback? onDoubleTap;         // When user double-taps quickly
  
  DoubleTapHoldGestureDetector({
    this.onGestureStart,
    this.onGestureDetected,
    this.onGestureCancelled,
    this.onDoubleTap,
  });

  /// Handle tap down
  void onTapDown(TapDownDetails details) {
    final now = DateTime.now();
    
    // Check if this is the second tap in quick succession
    if (_firstTapTime != null && 
        now.difference(_firstTapTime!) <= _doubleTapWindow) {
      // Second tap detected — start holding phase
      _isHolding = true;
      _gestureCompleted = false;
      _secondTapTime = now;
      onGestureStart?.call();
      
      // Start timer for hold duration
      _holdTimer?.cancel();
      _holdTimer = Timer(_holdDuration, () {
        if (_isHolding) {
          // Hold duration reached — gesture successful!
          _gestureCompleted = true;
          _isHolding = false;
          onGestureDetected?.call();
        }
      });
      
      _firstTapTime = null; // Reset
    } else {
      // First tap or previous timed out
      _firstTapTime = now;
      _gestureCompleted = false;
    }
  }

  /// Handle tap up / pointer up
  void onTapUp(TapUpDetails details) {
    if (_isHolding && !_gestureCompleted) {
      // User released BEFORE hold duration (600ms)
      final now = DateTime.now();
      final holdDuration = _secondTapTime != null 
          ? now.difference(_secondTapTime!) 
          : Duration.zero;

      _cancelGesture();

      // If they released quickly (< 300ms), we treat it as a deliberate double-tap
      if (holdDuration < const Duration(milliseconds: 300)) {
        onDoubleTap?.call();
      }
    }
    _isHolding = false;
  }

  /// Handle pointer move (away from initial tap)
  void onPointerMove(PointerMoveEvent event) {
    // Allow some movement — blind users may not tap precisely
  }

  /// Cancel gesture
  void _cancelGesture() {
    _holdTimer?.cancel();
    _isHolding = false;
    _gestureCompleted = false;
    onGestureCancelled?.call();
  }

  /// Reset gesture state
  void reset() {
    _holdTimer?.cancel();
    _firstTapTime = null;
    _isHolding = false;
    _gestureCompleted = false;
  }

  /// Clean up
  void dispose() {
    _holdTimer?.cancel();
  }
}

/// Scene Analysis Controller - manages analysis mode state and timing
class SceneAnalysisController with ChangeNotifier {
  AnalysisState _state = AnalysisState.idle;
  String _status = "";
  DateTime _lastAnalysisTime = DateTime.fromMillisecondsSinceEpoch(0);
  
  // Cooldown between analyses to prevent spam
  static const Duration _analysisCooldown = Duration(seconds: 2);
  
  // Current analysis progress
  int _analyzeProgress = 0; // 0-100
  String? _currentAnalysisError;

  AnalysisState get state => _state;
  String get status => _status;
  int get analyzeProgress => _analyzeProgress;
  String? get lastError => _currentAnalysisError;
  bool get isAnalyzing => _state == AnalysisState.analyzing;
  bool get isSpeaking => _state == AnalysisState.speaking;

  /// Check if enough time has passed since last analysis
  bool canAnalyze() {
    final elapsed = DateTime.now().difference(_lastAnalysisTime);
    return elapsed >= _analysisCooldown;
  }

  /// Start analysis
  void startAnalysis() {
    if (!canAnalyze()) {
      _currentAnalysisError = "Please wait before analyzing again";
      notifyListeners();
      return;
    }
    
    _state = AnalysisState.analyzing;
    _status = "Analyzing surroundings...";
    _analyzeProgress = 0;
    _currentAnalysisError = null;
    _lastAnalysisTime = DateTime.now();
    notifyListeners();
  }

  /// Update analysis progress
  void updateProgress(int percent) {
    _analyzeProgress = percent.clamp(0, 100);
    notifyListeners();
  }

  /// Analysis complete, move to speaking state
  void completeAnalysis({String status = "Analyzing..."}) {
    _state = AnalysisState.speaking;
    _status = status;
    _analyzeProgress = 100;
    notifyListeners();
  }

  /// Return to idle/navigation mode
  void returnToNavigation() {
    _state = AnalysisState.idle;
    _status = "";
    _analyzeProgress = 0;
    _currentAnalysisError = null;
    notifyListeners();
  }

  /// Cancel analysis
  void cancel() {
    _state = AnalysisState.cancelled;
    _status = "Cancelled";
    _currentAnalysisError = null;
    _analyzeProgress = 0;
    notifyListeners();
    
    // Auto return after brief delay
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_state == AnalysisState.cancelled) {
        returnToNavigation();
      }
    });
  }

  /// Set error state
  void setError(String error) {
    _currentAnalysisError = error;
    _status = "Error: $error";
    _state = AnalysisState.idle;
    notifyListeners();
  }

}

/// Builder class for formatting scene data for LLM
class SceneDataBuilder {
  final List<String> objects = [];
  
  /// Add a detected object with distance and direction
  void addObject({
    required String label,
    required String direction, // "left", "center", "right"
    String? distanceEstimate,
    double confidence = 0.8,
  }) {
    if (confidence < 0.5) return; // Skip low confidence detections
    
    String formattedObject = label;
    
    if (distanceEstimate != null && distanceEstimate.isNotEmpty) {
      formattedObject += " $distanceEstimate";
    }
    
    // Convert center to "ahead" or "in front"
    final dirText = direction == "center" ? "ahead" : direction;
    formattedObject += " $dirText";
    
    objects.add(formattedObject);
  }

  /// Sort by relevance and limit to top N objects
  void sortAndLimit({int maxObjects = 3}) {
    // In a real implementation, you'd sort by distance/relevance
    // For now, just limit
    if (objects.length > maxObjects) {
      objects.removeRange(maxObjects, objects.length);
    }
  }

  /// Get formatted scene data
  List<String> build() {
    sortAndLimit();
    return objects;
  }

  /// Clear data
  void clear() {
    objects.clear();
  }
}