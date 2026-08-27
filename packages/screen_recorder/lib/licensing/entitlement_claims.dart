/// Claims carried by a server-issued Ed25519 entitlement token (spec §4).
class EntitlementClaims {
  const EntitlementClaims({
    required this.sub,
    required this.plan,
    required this.exportEntitled,
    required this.status,
    required this.updatesUntil,
    required this.deviceId,
    required this.seatLimit,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String sub;
  final String plan; // 'subscription' | 'onetime' | 'free'
  final bool exportEntitled;
  final String status; // 'active' | 'grace' | 'canceled' | 'none'
  final DateTime? updatesUntil;
  final String deviceId;
  final int seatLimit;
  final DateTime issuedAt;
  final DateTime expiresAt;

  factory EntitlementClaims.fromJson(Map<String, dynamic> json) {
    DateTime fromEpochSeconds(Object? v) =>
        DateTime.fromMillisecondsSinceEpoch(((v as num).toInt()) * 1000, isUtc: true);
    final rawUntil = json['updates_until'];
    return EntitlementClaims(
      sub: json['sub'] as String,
      plan: json['plan'] as String,
      exportEntitled: json['export'] as bool? ?? false,
      status: json['status'] as String? ?? 'none',
      updatesUntil: rawUntil == null ? null : DateTime.parse(rawUntil as String).toUtc(),
      deviceId: json['device_id'] as String? ?? '',
      seatLimit: (json['seat_limit'] as num?)?.toInt() ?? 0,
      issuedAt: fromEpochSeconds(json['iat']),
      expiresAt: fromEpochSeconds(json['exp']),
    );
  }
}
