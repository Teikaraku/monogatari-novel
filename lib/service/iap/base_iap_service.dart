import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:flutter/widgets.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

enum IAPStatus {
  purchased,
  trial,
  trialExpired,
  originalUser,
  unknown,
}

extension IapStatusTitle on IAPStatus {
  String title(BuildContext context) {
    switch (this) {
      case IAPStatus.purchased:
        return L10n.of(context).iapStatusPurchased;
      case IAPStatus.trial:
        return L10n.of(context).iapStatusTrial;
      case IAPStatus.trialExpired:
        return L10n.of(context).iapStatusTrialExpired;
      case IAPStatus.originalUser:
        return L10n.of(context).iapStatusOriginal;
      default:
        return L10n.of(context).iapStatusUnknown;
    }
  }
}

/// A snapshot of platform-specific information returned by the store layer.
///
/// The provider uses this data to derive user-facing state and cache updates.
class IapPlatformSnapshot {
  IapPlatformSnapshot({
    required this.hasPurchase,
    required this.isPurchaseStatusReliable,
    required this.trialStartDate,
    required this.purchaseDate,
    required this.isOriginalUser,
    this.receiptRefreshFailed = false,
  });

  /// Whether the platform reported an active purchase.
  /// Can be null when the platform cannot answer (e.g., Play without restore).
  final bool? hasPurchase;

  /// Whether [hasPurchase] is authoritative enough to write back to prefs.
  final bool isPurchaseStatusReliable;

  /// Trial start date (install date on Play, original purchase date on App Store).
  final DateTime? trialStartDate;

  /// Latest known purchase date, if any.
  final DateTime? purchaseDate;

  /// Whether this is considered an “original user” (legacy free users on iOS).
  final bool isOriginalUser;

  /// Whether receipt refresh failed (iOS only). When true, the provider
  /// should trust cached purchase status instead of clearing it.
  final bool receiptRefreshFailed;
}

abstract class BaseIAPService {
  BaseIAPService({required this.trialDays});

  final int trialDays;

  String get storeName;
  String get productId;

  Future<void> initialize();
  Future<bool> isAvailable();
  Future<ProductDetailsResponse> queryProductDetails();
  Future<void> buy(ProductDetails productDetails);
  Future<void> restorePurchases();
  Future<void> completePurchase(PurchaseDetails purchaseDetails);
  Stream<List<PurchaseDetails>> get purchaseUpdates;

  /// Pulls the latest platform information (receipt/installation info/etc.).
  Future<IapPlatformSnapshot> loadSnapshot();
}
