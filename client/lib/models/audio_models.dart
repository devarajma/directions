// ── audio priority levels ──────────────────────────────────────────────────────
enum AudioPriority { low, normal, high, critical }

// ── pending speech item ────────────────────────────────────────────────────────
class SpeechItem {
  final String        message;
  final AudioPriority priority;
  final DateTime      queuedAt;
  SpeechItem(this.message, this.priority) : queuedAt = DateTime.now();
}
