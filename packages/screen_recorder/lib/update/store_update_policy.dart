/// Build numbers are monotonic across App Store releases. A policy must refer
/// to an available release before it can offer or require an update.
class StoreUpdatePolicy {
  const StoreUpdatePolicy({
    required this.build,
    required this.version,
    required this.required,
  });
  final int build;
  final String version;
  final bool required;

  static StoreUpdatePolicy? parse(
    Map<String, Object?> values,
    int currentBuild,
  ) {
    if (values['store_update_available'] != true || currentBuild <= 0) {
      return null;
    }
    final latest = int.tryParse('${values['store_latest_build']}');
    final minimum = int.tryParse('${values['store_minimum_build']}');
    final version = values['store_latest_version'];
    if (latest == null ||
        minimum == null ||
        minimum < 0 ||
        minimum > latest ||
        latest <= currentBuild ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      return null;
    }
    return StoreUpdatePolicy(
      build: latest,
      version: version,
      required: currentBuild < minimum,
    );
  }
}
