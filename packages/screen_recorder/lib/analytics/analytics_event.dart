/// A generic PostHog event. `AnalyticsEvent` predates the split into product
/// analytics vs diagnostics vs feedback; all three now share this shape.
typedef PostHogEvent = AnalyticsEvent;

/// One captured product-analytics event, awaiting delivery to PostHog.
///
/// Deliberately content-free: `name` plus cheap, non-identifying `properties`
/// (durations, formats, counts). Never put file paths, window titles, captured
/// pixels, or any recording content in here — this is a screen recorder.
class AnalyticsEvent {
  const AnalyticsEvent({
    required this.name,
    required this.timestamp,
    this.properties = const {},
  });

  final String name;
  final DateTime timestamp;
  final Map<String, Object?> properties;

  /// Shape for a PostHog `/batch/` item. `distinct_id` is attached at send
  /// time (it is constant per install) rather than stored per event.
  Map<String, dynamic> toBatchItem(String distinctId) => {
        'event': name,
        'distinct_id': distinctId,
        'properties': properties,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  /// Persisted shape for the on-disk offline queue.
  Map<String, dynamic> toJson() => {
        'name': name,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'properties': properties,
      };

  static AnalyticsEvent? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final ts = json['timestamp'];
    if (name is! String || ts is! String) return null;
    final when = DateTime.tryParse(ts);
    if (when == null) return null;
    final props = json['properties'];
    return AnalyticsEvent(
      name: name,
      timestamp: when,
      properties: props is Map<String, dynamic>
          ? props.map((k, v) => MapEntry(k, v as Object?))
          : const {},
    );
  }
}
