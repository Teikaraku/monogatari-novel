import 'package:anx_reader/providers/iap.dart';
import 'package:anx_reader/service/iap/base_iap_service.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

part 'iap_state.freezed.dart';

@freezed
abstract class IapState with _$IapState {
  const factory IapState({
    required bool isInitialized,
    required bool isAvailable,
    required IAPStatus status,
    DateTime? trialStartDate,
    required int trialDaysLeft,
    DateTime? purchaseDate,
    required DateTime lastChecked,
    required bool isOriginalUser,
    required IapPurchaseFlowStatus purchaseFlowStatus,
    String? errorMessage,
    required bool isRefreshing,
    required bool isRestoring,
    required bool isPurchasing,
    required List<ProductDetails> products,
    required String storeName,
  }) = _IapState;

  const IapState._();

  bool get isPurchased =>
      status == IAPStatus.purchased || status == IAPStatus.originalUser;

  bool get isFeatureAvailable =>
      status == IAPStatus.purchased ||
      status == IAPStatus.originalUser ||
      status == IAPStatus.trial;
}
