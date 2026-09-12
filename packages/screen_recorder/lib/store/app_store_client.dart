import 'dart:async';
import 'package:flutter/services.dart';
import '../licensing/entitlement.dart';

class StoreProduct {
  const StoreProduct(
    this.id,
    this.title,
    this.price,
    this.period, {
    this.priceValue,
    this.currencyCode,
  });
  final String id, title, price;
  final String? period;
  final double? priceValue;
  final String? currencyCode;

  int? savingsComparedWith(StoreProduct monthly) {
    final annual = priceValue, month = monthly.priceValue;
    if (!isYearly ||
        monthly.isYearly ||
        currencyCode == null ||
        currencyCode != monthly.currencyCode ||
        annual == null ||
        month == null ||
        !annual.isFinite ||
        !month.isFinite ||
        annual <= 0 ||
        month <= 0 ||
        annual >= month * 12) {
      return null;
    }
    final savings = ((1 - annual / (month * 12)) * 100).floor();
    return savings > 0 ? savings : null;
  }

  bool get isYearly => id == 'com.slipreel.store.yearly';
  String get purchaseLabel =>
      isYearly ? 'Yearly · $price / year' : 'Monthly · $price / month';
  String get billingLabel => isYearly
      ? '$price charged yearly. Renews every year.'
      : '$price charged monthly. Renews every month.';
  factory StoreProduct.fromMap(Map<Object?, Object?> map) => StoreProduct(
    map['id'] as String,
    map['title'] as String,
    map['price'] as String,
    map['period'] as String?,
    priceValue: (map['priceValue'] as num?)?.toDouble(),
    currencyCode: map['currencyCode'] as String?,
  );
}

/// No entitlement JSON is persisted by Dart. StoreKit verifies Apple's signed
/// transactions on every launch and publishes refunds/renewals while running.
class AppStoreClient {
  AppStoreClient({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('slipreel/store');
  final MethodChannel channel;
  void Function()? onChange;
  Future<void> initialize() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'transactionsChanged') onChange?.call();
    });
    if (await channel.invokeMethod<String>('channel') != 'app-store') {
      throw StateError('Dart/native distribution mismatch');
    }
  }

  Future<List<StoreProduct>> products() async =>
      (await channel
                  .invokeListMethod<Object?>('products')
                  .timeout(const Duration(seconds: 15)) ??
              [])
          .map((p) => StoreProduct.fromMap(p as Map<Object?, Object?>))
          .toList();
  Future<EntitlementAppStore> entitlement() async {
    final map = await channel
        .invokeMapMethod<String, Object?>('entitlement')
        .timeout(const Duration(seconds: 15));
    if (map == null) throw StateError('StoreKit unavailable');
    return EntitlementAppStore(
      productId: map['productId'] as String?,
      expiresAt: map['expiresAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (map['expiresAt'] as num).toInt(),
              isUtc: true,
            ),
    );
  }

  Future<String> purchase(String id, String appAccountToken) async =>
      await channel.invokeMethod<String>('purchase', {
        'id': id,
        'appAccountToken': appAccountToken,
      }) ??
      'failed';
  Future<List<String>> signedTransactions() async =>
      await channel
          .invokeListMethod<String>('signedTransactions')
          .timeout(const Duration(seconds: 15)) ??
      [];
  Future<void> restore() => channel
      .invokeMethod<void>('restore')
      .timeout(const Duration(seconds: 45));
  Future<void> manageSubscriptions() =>
      channel.invokeMethod<void>('manageSubscriptions');
  void dispose() {
    onChange = null;
    channel.setMethodCallHandler(null);
  }
}
