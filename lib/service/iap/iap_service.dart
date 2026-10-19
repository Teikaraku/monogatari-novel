import 'package:anx_reader/utils/platform_utils.dart';

import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:anx_reader/service/iap/app_store_iap_service.dart';
import 'package:anx_reader/service/iap/base_iap_service.dart';
import 'package:anx_reader/service/iap/play_store_iap_service.dart';

export 'package:anx_reader/service/iap/base_iap_service.dart'
    show IAPStatus, IapPlatformSnapshot, IapStatusTitle;

class NoopIAPService extends BaseIAPService {
  NoopIAPService({required super.trialDays});

  @override
  String get storeName => 'In-App Purchase';

  @override
  String get productId => 'noop';

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<ProductDetailsResponse> queryProductDetails() async {
    return ProductDetailsResponse(productDetails: [], notFoundIDs: []);
  }

  @override
  Future<void> buy(ProductDetails productDetails) async {}

  @override
  Future<void> completePurchase(PurchaseDetails purchaseDetails) async {}

  @override
  Future<void> restorePurchases() async {}

  @override
  Stream<List<PurchaseDetails>> get purchaseUpdates =>
      const Stream<List<PurchaseDetails>>.empty();

  @override
  Future<IapPlatformSnapshot> loadSnapshot() async {
    return IapPlatformSnapshot(
      hasPurchase: false,
      isPurchaseStatusReliable: true,
      trialStartDate: DateTime.fromMillisecondsSinceEpoch(0),
      purchaseDate: null,
      isOriginalUser: false,
    );
  }
}

class IAPService {
  IAPService._internal() : _delegate = _buildDelegate();

  factory IAPService() => _instance;

  static final IAPService _instance = IAPService._internal();

  static const int kTrialDays = 7;
  static const int kMaxValidationInterval = 7 * 24 * 60 * 60 * 1000;

  final BaseIAPService _delegate;

  BaseIAPService get delegate => _delegate;

  static BaseIAPService _buildDelegate() {
    if (AnxPlatform.isIOS || AnxPlatform.isMacOS) {
      return AppStoreIAPService(
        trialDays: kTrialDays,
      );
    }

    if (AnxPlatform.isAndroid) {
      return PlayStoreIAPService(
        trialDays: kTrialDays,
      );
    }

    return NoopIAPService(trialDays: kTrialDays);
  }

  Future<void> initialize() => _delegate.initialize();

  Future<bool> isAvailable() => _delegate.isAvailable();

  Future<ProductDetailsResponse> queryProductDetails() =>
      _delegate.queryProductDetails();

  Future<void> buy(ProductDetails productDetails) =>
      _delegate.buy(productDetails);

  Future<void> completePurchase(PurchaseDetails purchaseDetails) =>
      _delegate.completePurchase(purchaseDetails);

  Future<void> restorePurchases() => _delegate.restorePurchases();

  Stream<List<PurchaseDetails>> get purchaseUpdates =>
      _delegate.purchaseUpdates;

  Future<IapPlatformSnapshot> loadSnapshot() => _delegate.loadSnapshot();

  String get storeName => _delegate.storeName;
  String get productId => _delegate.productId;
}
