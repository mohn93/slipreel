/// A generic PostHog event. `AnalyticsEvent` predates the split into product
/// analytics vs diagnostics vs feedback; all three now share this shape.
typedef PostHogEvent = AnalyticsEvent;

/// One PostHog event awaiting delivery — a `name`, a `timestamp`, and a
/// `properties` map. Aliased as [PostHogEvent] (above) because it now backs
/// product analytics, diagnostics (`$exception`), and feedback alike.
///
/// Product-analytics events stay deliberately content-free (cheap,
/// non-identifying props — durations, formats, counts). Diagnostics and
/// feedback events may carry richer content (stack frames, breadcrumbs, a typed
/// message), but always scrubbed by `PiiScrubber` before it lands here — never
/// raw file paths, window titles, or recording content.
class AnalyticsEvent {
  const AnalyticsEvent({
    required this.name,
    required this.timestamp,
    this.properties = const {},
    this.distinctId,
  });

  /// Identity captured when queued, never reassigned at delivery.
  final String? distinctId;
  AnalyticsEvent withIdentity(String id) => AnalyticsEvent(
    name: name,
    timestamp: timestamp,
    properties: properties,
    distinctId: id,
  );

  final String name;
  final DateTime timestamp;
  final Map<String, Object?> properties;

  /// The fallback supports callers constructing an event before enqueue.
  Map<String, dynamic> toBatchItem(String distinctId) => {
    'event': name,
    'distinct_id': this.distinctId ?? distinctId,
    'properties': properties,
    'timestamp': timestamp.toUtc().toIso8601String(),
  };

  /// Persisted shape for the on-disk offline queue.
  Map<String, dynamic> toJson() => {
    'name': name,
    if (distinctId != null) 'distinct_id': distinctId,
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
      distinctId: json['distinct_id'] is String
          ? json['distinct_id'] as String
          : null,
      timestamp: when,
      properties: props is Map<String, dynamic>
          ? props.map((k, v) => MapEntry(k, v as Object?))
          : const {},
    );
  }
}
