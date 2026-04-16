import 'package:http/http.dart' as http;
import 'dart:convert';

/// Model for YOLO detection from server
class YOLODetection {
  final String label;
  final double confidence;
  final int x1, y1, x2, y2; // Bounding box
  final double depth; // 0-1, where 1 = very close
  final String depthProximity; // "close", "medium", "far"
  final String distanceEstimate; // e.g., "1.5 feet", "2 meters"

  YOLODetection({
    required this.label,
    required this.confidence,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.depth,
    required this.depthProximity,
    required this.distanceEstimate,
  });

  /// Get zone based on bounding box position
  String getZone(int frameWidth) {
    final cx = (x1 + x2) ~/ 2;
    final third = frameWidth ~/ 3;
    
    if (cx < third) return "left";
    if (cx < 2 * third) return "center";
    return "right";
  }

  /// Convert to human-readable format for LLM
  String toSceneFormat(int frameWidth) {
    final zone = getZone(frameWidth);
    final directionText = zone == "center" ? "ahead" : zone;
    
    if (distanceEstimate.isNotEmpty) {
      return "$label ${distanceEstimate} $directionText";
    } else {
      return "$label $directionText";
    }
  }

  factory YOLODetection.fromJson(Map<String, dynamic> json) {
    return YOLODetection(
      label: json['label'] as String? ?? 'object',
      confidence: (json['conf'] as num?)?.toDouble() ?? 0.0,
      x1: json['x1'] as int? ?? 0,
      y1: json['y1'] as int? ?? 0,
      x2: json['x2'] as int? ?? 640,
      y2: json['y2'] as int? ?? 480,
      depth: (json['depth'] as num?)?.toDouble() ?? 0.5,
      depthProximity: json['depth_proximity'] as String? ?? 'medium',
      distanceEstimate: json['distance_est'] as String? ?? '',
    );
  }
}

/// Full scene data from server
class SceneSnapshot {
  final String message;
  final List<YOLODetection> alerts;
  final bool safe;
  final double timestamp;
  final int frameWidth;
  final int frameHeight;

  SceneSnapshot({
    required this.message,
    required this.alerts,
    required this.safe,
    required this.timestamp,
    this.frameWidth = 640,
    this.frameHeight = 480,
  });

  /// Get top N closest objects
  List<YOLODetection> getTopObjects({int limit = 3}) {
    final sorted = List<YOLODetection>.from(alerts);
    sorted.sort((a, b) => b.depth.compareTo(a.depth)); // Sort by depth desc
    return sorted.take(limit).toList();
  }

  /// Format scene for LLM analysis
  List<String> formatForLLM({int maxObjects = 3}) {
    final top = getTopObjects(limit: maxObjects);
    return top
        .map((det) => det.toSceneFormat(frameWidth))
        .where((s) => s.isNotEmpty)
        .toList();
  }

  factory SceneSnapshot.fromJson(
    Map<String, dynamic> json, {
    int frameWidth = 640,
    int frameHeight = 480,
  }) {
    final alertsList = (json['alerts'] as List?)
            ?.map((a) => YOLODetection.fromJson(a as Map<String, dynamic>))
            .toList() ??
        [];

    return SceneSnapshot(
      message: json['message'] as String? ?? 'No data',
      alerts: alertsList,
      safe: json['safe'] as bool? ?? true,
      timestamp: (json['timestamp'] as num?)?.toDouble() ?? 0.0,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
    );
  }
}

/// Server communication handler
class SceneAnalysisServerClient {
  final String serverUrl;

  SceneAnalysisServerClient({
    required this.serverUrl,
  });

  /// Fetch detailed scene data from server (YOLO + Depth Anything V2)
  /// Uses the /scene endpoint which runs depth analysis on-demand
  Future<SceneSnapshot?> fetchLatestScene({
    int frameWidth = 640,
    int frameHeight = 480,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      print("📡 Calling /scene endpoint...");
      final response = await http
          .get(Uri.parse("$serverUrl/scene"))
          .timeout(timeout);

      if (response.statusCode != 200) {
        print("❌ /scene error: ${response.statusCode} - ${response.body}");
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      print("✅ /scene response: ${(data['alerts'] as List?)?.length ?? 0} objects, "
            "depth_available: ${data['depth_available']}");

      return SceneSnapshot.fromJson(
        data,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
      );
    } catch (e) {
      print("❌ Error fetching scene data: $e");
      return null;
    }
  }

  /// Fetch raw navigation data (for debugging)
  Future<Map<String, dynamic>?> fetchRawNav({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final response = await http
          .get(Uri.parse("$serverUrl/nav"))
          .timeout(timeout);

      if (response.statusCode != 200) {
        return null;
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      print("Error fetching raw nav: $e");
      return null;
    }
  }
}

/// Complete analysis result from gesture
class AnalysisResult {
  final List<String> detectedObjects; // Formatted scene data
  final String llmDescription; // LLM-generated description
  final bool success;
  final String? error;
  final Duration processingTime;

  AnalysisResult({
    required this.detectedObjects,
    required this.llmDescription,
    required this.success,
    this.error,
    required this.processingTime,
  });

  @override
  String toString() =>
      "AnalysisResult(success: $success, objects: ${detectedObjects.length}, time: ${processingTime.inMilliseconds}ms)";
}