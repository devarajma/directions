import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:convert';

/// Groq API integration for scene analysis using LLaMA 3
class GroqLLMService {
  static const String _apiUrl = "https://api.groq.com/openai/v1/chat/completions";
  
  // You need to set your API key in the environment or pass it here
  final String apiKey;

  GroqLLMService({required this.apiKey});

  /// Convert scene data to natural language description using LLaMA 3
  /// 
  /// Input:
  /// - sceneData: List of detected objects with distance and direction
  ///   Example: ["Chair 1.5 feet ahead", "Table 3 feet right"]
  /// 
  /// Output:
  /// - String: Natural language description (max 2 sentences, under 20 words)
  static Future<String> analyzeScene({
    required List<String> sceneObjects,
    required String apiKey,
    int maxRetries = 2,
  }) async {
    try {
      // Format scene data
      final sceneData = sceneObjects.join(", ");
      
      if (sceneData.isEmpty) {
        print("⚠️ Groq: No scene data to analyze");
        return "No major objects nearby.";
      }

      // Validate: don't waste API calls on useless data
      if (sceneObjects.every((s) => s.trim().isEmpty)) {
        print("⚠️ Groq: All scene objects are empty strings");
        return "No identifiable objects nearby.";
      }

      print("🤖 Groq: Sending ${sceneObjects.length} objects: $sceneData");

      // Create prompt
      final prompt = _buildPrompt(sceneData);

      // Call Groq API
      final response = await _callGroqAPI(
        prompt: prompt,
        apiKey: apiKey,
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException("Groq API timeout after 5s"),
      );

      // Log response details
      print("🤖 Groq: Response status=${response.statusCode}");
      
      if (response.statusCode != 200) {
        print("❌ Groq API error ${response.statusCode}: ${response.body}");
        return "Analysis service error. Try again.";
      }

      // Parse response
      final text = _parseGroqResponse(response);
      print("🤖 Groq: Result = \"$text\"");
      return text.isNotEmpty ? text : "Scene analyzed but no description generated.";
      
    } on TimeoutException {
      print("❌ Groq API timed out");
      return "Analysis timed out. Try again.";
    } catch (e) {
      print("❌ Groq LLM error: $e");
      return "Analysis failed: ${e.toString().split('\n').first}";
    }
  }

  /// Build system and user prompt for scene analysis
  static String _buildPrompt(String sceneData) {
    return '''You are an assistive AI helping a visually impaired person understand their surroundings.

Convert this scene data into a SHORT, CLEAR spoken description.

RULES:
- Maximum 2 sentences
- Keep under 20 words total
- Mention closest object first
- Use simple, natural language
- Include direction: left, right, or in front
- WARN if object is very close (< 2 feet)
- No explanations, just the scene description

SCENE DATA:
$sceneData

RESPONSE (only the description, nothing else):''';
  }

  /// Call Groq API with LLaMA 3
  static Future<http.Response> _callGroqAPI({
    required String prompt,
    required String apiKey,
  }) async {
    final body = {
      "model": "llama-3.1-8b-instant",
      "messages": [
        {
          "role": "user",
          "content": prompt,
        }
      ],
      "temperature": 0.3, // Low temp for consistency
      "max_tokens": 150,
      "top_p": 0.9,
    };

    return http.post(
      Uri.parse(_apiUrl),
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer $apiKey",
      },
      body: jsonEncode(body),
    );
  }

  /// Parse response from Groq API
  static String _parseGroqResponse(http.Response response) {
    try {
      if (response.statusCode != 200) {
        print("Groq API error: ${response.statusCode} - ${response.body}");
        return "";
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      
      if (choices == null || choices.isEmpty) {
        return "";
      }

      final message = choices[0]['message'] as Map<String, dynamic>?;
      final content = message?['content'] as String?;

      return content?.trim() ?? "";
    } catch (e) {
      print("Error parsing Groq response: $e");
      return "";
    }
  }
}

/// Scene object data class
class SceneObject {
  final String label;
  final double depth; // 0-1, where 1 = very close, 0 = far
  final String direction; // "left", "center" (in front), "right"
  final String? distanceEstimate; // e.g., "1.5 feet", "2 meters"
  final double confidence;

  SceneObject({
    required this.label,
    required this.depth,
    required this.direction,
    this.distanceEstimate,
    this.confidence = 0.8,
  });

  /// Convert to natural language format for LLM
  String toNaturalLanguage() {
    final directionText = direction == "center" ? "ahead" : direction;
    if (distanceEstimate != null && distanceEstimate!.isNotEmpty) {
      return "$label ${distanceEstimate!} $directionText";
    } else {
      return "$label $directionText";
    }
  }

  @override
  String toString() => toNaturalLanguage();
}