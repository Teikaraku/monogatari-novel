import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/iap_state.dart';
import 'package:anx_reader/service/iap/iap_service.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'iap.g.dart';

enum IapPurchaseFlowStatus { idle, pending, purchased, restored, error }

enum _RefreshPolicy { positiveOnly, full }

@Riverpod(keepAlive: true)
class Iap extends _$Iap {
  final IAPService _iapService = IAPService();
  StreamSubscription<List<PurchaseDetails>>? _subscription;

  @override
  Future<IapState> build() async {
    _subscription ??= _iapService.purchaseUpdates.listen(
      _handlePurchaseUpdates,
      onError: (Object error, StackTrace stack) {
        AnxLog.severe('IAP: purchase stream error: $error', stack);
        _updateState((current) => current.copyWith(
              purchaseFlowStatus: IapPurchaseFlowStatus.error,
              errorMessage: error.toString(),
            ));
      },
    );

    await _iapService.initialize();
    final available = await _iapService.isAvailable();
    final snapshot = await _iapService.loadSnapshot();

    final cachedPurchased = Prefs().iapPurchaseStatus;
    final lastCheck = Prefs().iapLastCheckTime;
    final cacheFresh = _isCacheFresh(lastCheck);

    AnxLog.info(
      'IAP: initialized. available=$available, '
      'snapshot.hasPurchase=${snapshot.hasPurchase}, '
      'cachedPurchased=$cachedPurchased, '
      'lastCheck=$lastCheck, '
      'cacheFresh=$cacheFresh',
    );

    final trialStart =
        snapshot.trialStartDate ?? (lastCheck.year == 1970 ? null : lastCheck);
    final trialDaysLeft = _trialDaysLeft(trialStart);

    final initialPurchased = cachedPurchased || snapshot.hasPurchase == true;
    final status = _deriveStatus(
      purchased: initialPurchased,
      isOriginalUser: snapshot.isOriginalUser,
      trialDaysLeft: trialDaysLeft,
    );

    final initialState = IapState(
      isInitialized: true,
      isAvailable: available,
      status: status,
      trialStartDate: trialStart,
      trialDaysLeft: trialDaysLeft,
      purchaseDate: snapshot.purchaseDate,
      lastChecked: lastCheck,
      isOriginalUser: snapshot.isOriginalUser,
      purchaseFlowStatus: IapPurchaseFlowStatus.idle,
      errorMessage:
          available ? null : '${_iapService.storeName} is not available',
      isRefreshing: false,
      isRestoring: false,
      isPurchasing: false,
      products: const [],
      storeName: _iapService.storeName,
    );

    // Publish the initial snapshot before background refreshes.
    state = AsyncValue.data(initialState);

    if (available) {
      _primeRefresh(
        cachedPurchased: cachedPurchased,
        cacheFresh: cacheFresh,
      );
      unawaited(loadProducts());
    }

    return initialState;
  }

  Future<void> loadProducts() async {
    final current = state.valueOrNull;
    if (current == null) return;

    try {
      final response = await _iapService.queryProductDetails();
      if (response.error != null) {
        _updateState(
          (c) => c.copyWith(
            errorMessage:
                'Error connecting to store: ${response.error?.message}',
          ),
        );
        return;
      }

      if (response.notFoundIDs.isNotEmpty) {
        _updateState(
          (c) => c.copyWith(
            errorMessage:
                'Product IDs not found: ${response.notFoundIDs.join(", ")}',
          ),
        );
        return;
      }

      if (response.productDetails.isEmpty) {
        _updateState(
          (c) => c.copyWith(
            errorMessage:
                'No product information found, please ensure products are correctly configured in ${_iapService.storeName}',
          ),
        );
        return;
      }

      _updateState(
        (c) => c.copyWith(
          products: response.productDetails,
          errorMessage: null,
        ),
      );
    } catch (e, stack) {
      AnxLog.severe('IAP: loadProducts error: $e', stack);
      _updateState(
        (c) => c.copyWith(
          errorMessage: 'Error loading product information: $e',
        ),
      );
    }
  }

  Future<void> buy() async {
    final current = state.valueOrNull;
    if (current == null || current.isPurchasing) return;

    var products = current.products;
    if (products.isEmpty) {
      await loadProducts();
      products = state.valueOrNull?.products ?? [];
    }

    if (products.isEmpty) {
      _updateState(
        (c) => c.copyWith(
          errorMessage: 'No products available for purchase',
          purchaseFlowStatus: IapPurchaseFlowStatus.error,
        ),
      );
      return;
    }

    _updateState((c) => c.copyWith(
          isPurchasing: true,
          errorMessage: null,
          purchaseFlowStatus: IapPurchaseFlowStatus.idle,
        ));

    try {
      await _iapService.buy(products.first);
    } catch (e, stack) {
      AnxLog.severe('IAP: buy error: $e', stack);
      _updateState((c) => c.copyWith(
            isPurchasing: false,
            purchaseFlowStatus: IapPurchaseFlowStatus.error,
            errorMessage: e.toString(),
          ));
    }
  }

  Future<void> restore() async {
    final current = state.valueOrNull;
    if (current == null) return;

    _updateState(
      (c) => c.copyWith(
        isRestoring: true,
        errorMessage: null,
        purchaseFlowStatus: IapPurchaseFlowStatus.idle,
      ),
    );

    try {
      await _iapService.restorePurchases();

      // Wait for purchase stream to respond with a timeout
      // The purchase updates will be handled by _handlePurchaseUpdates
      await Future.delayed(const Duration(seconds: 5));

      // Check if we got any restore result
      final afterState = state.valueOrNull;
      if (afterState != null &&
          afterState.isRestoring &&
          afterState.purchaseFlowStatus == IapPurchaseFlowStatus.idle) {
        // No purchase update received after restore - no purchases found
        AnxLog.warning('IAP: Restore completed but no purchases found');
        _updateState(
          (c) => c.copyWith(
            isRestoring: false,
            purchaseFlowStatus: IapPurchaseFlowStatus.error,
            errorMessage:
                'No purchases found to restore. If you have purchased, please check your Apple ID and network connection.',
          ),
        );
      }
    } catch (e, stack) {
      AnxLog.severe('IAP: restore error: $e', stack);
      _updateState(
        (c) => c.copyWith(
          isRestoring: false,
          purchaseFlowStatus: IapPurchaseFlowStatus.error,
          errorMessage: e.toString(),
        ),
      );
    } finally {
      // Only set isRestoring to false if it wasn't already handled
      final finalState = state.valueOrNull;
      if (finalState?.isRestoring == true) {
        _updateState((c) => c.copyWith(isRestoring: false));
      }
    }
  }

  Future<void> refresh({bool userInitiated = false}) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final policy = userInitiated ? _RefreshPolicy.full : _RefreshPolicy.full;

    _updateState((c) => c.copyWith(
          isRefreshing: true,
          errorMessage: null,
        ));

    try {
      await _refreshEntitlement(policy: policy);
    } catch (e, stack) {
      AnxLog.severe('IAP: refresh error: $e', stack);
      _updateState(
        (c) => c.copyWith(
          isRefreshing: false,
          isRestoring: false,
          purchaseFlowStatus: IapPurchaseFlowStatus.error,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  bool cachedFeatureAvailable() {
    if (Prefs().iapPurchaseStatus) {
      return true;
    }

    final lastCheck = Prefs().iapLastCheckTime;
    final trialStart =
        lastCheck.year == 1970 ? DateTime.now() : Prefs().iapLastCheckTime;
    final trialLeft = _trialDaysLeft(trialStart);
    return trialLeft > 0;
  }

  Future<void> _primeRefresh({
    required bool cachedPurchased,
    required bool cacheFresh,
  }) async {
    AnxLog.info(
      'IAP: priming refresh. cachedPurchased=$cachedPurchased, cacheFresh=$cacheFresh',
    );

    if (cacheFresh) {
      final policy =
          cachedPurchased ? _RefreshPolicy.positiveOnly : _RefreshPolicy.full;
      unawaited(_refreshEntitlement(policy: policy));
      return;
    }

    _invalidateCachedPurchase();
    unawaited(
      _refreshEntitlement(
        policy: _RefreshPolicy.full,
      ),
    );
  }

  Future<void> _refreshEntitlement({
    required _RefreshPolicy policy,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final snapshot = await _iapService.loadSnapshot();
    final now = DateTime.now();

    var purchased = current.isPurchased;
    final cachedPurchased = Prefs().iapPurchaseStatus;

    AnxLog.info(
      'IAP: refreshEntitlement: policy=$policy, '
      'snapshot.hasPurchase=${snapshot.hasPurchase}, '
      'isPurchaseStatusReliable=${snapshot.isPurchaseStatusReliable}, '
      'receiptRefreshFailed=${snapshot.receiptRefreshFailed}, '
      'cachedPurchased=$cachedPurchased',
    );

    if (snapshot.hasPurchase == true && snapshot.isPurchaseStatusReliable) {
      purchased = true;
      _writePurchaseCache(true, now);
      return;
    } else if (snapshot.receiptRefreshFailed && cachedPurchased) {
      // Receipt refresh failed but user has cached purchase - trust the cache
      // and attempt restore to verify. Don't clear their purchase status.
      AnxLog.info(
          'IAP: Receipt refresh failed, trusting cached purchase status');
      purchased = true;
      // Don't update cache timestamp to trigger another check later
    } else if (policy == _RefreshPolicy.full) {
      purchased = false;
      _writePurchaseCache(false, now);
    }

    final trialStart = snapshot.trialStartDate ?? current.trialStartDate;
    final trialDaysLeft = _trialDaysLeft(trialStart);
    final status = _deriveStatus(
      purchased: purchased,
      isOriginalUser: snapshot.isOriginalUser,
      trialDaysLeft: trialDaysLeft,
    );

    _updateState(
      (c) => c.copyWith(
        status: status,
        trialStartDate: trialStart,
        trialDaysLeft: trialDaysLeft,
        purchaseDate: snapshot.purchaseDate ?? c.purchaseDate,
        isOriginalUser: snapshot.isOriginalUser,
        lastChecked: Prefs().iapLastCheckTime,
        isRefreshing: false,
      ),
    );

    await _restoreSilently();
  }

  void _invalidateCachedPurchase() {
    final current = state.valueOrNull;
    if (current == null) {
      _writePurchaseCache(false, DateTime.now());
      return;
    }
    final now = DateTime.now();
    _writePurchaseCache(false, now);
    final status = _deriveStatus(
      purchased: false,
      isOriginalUser: current.isOriginalUser,
      trialDaysLeft: current.trialDaysLeft,
    );

    _updateState(
      (c) => c.copyWith(
        status: status,
        lastChecked: now,
      ),
    );
  }

  Future<void> _restoreSilently() async {
    try {
      await _iapService.restorePurchases();
    } catch (e, stack) {
      AnxLog.warning('IAP: silent restore error: $e', stack);
    }
  }

  void _handlePurchaseUpdates(List<PurchaseDetails> purchaseDetailsList) async {
    AnxLog.info(
      'IAP: Received ${purchaseDetailsList.length} purchase update(s)',
    );
    for (final purchaseDetails in purchaseDetailsList) {
      AnxLog.info('IAP: Processing purchase update:'
          'pendingCompletePurchase: ${purchaseDetails.pendingCompletePurchase},'
          'productID: ${purchaseDetails.productID},'
          'status: ${purchaseDetails.status.name},'
          'purchaseID: ${purchaseDetails.purchaseID},'
          'transactionDate: ${purchaseDetails.transactionDate},'
          'error: ${purchaseDetails.error?.message},'
          'verificationData: ${purchaseDetails.verificationData.localVerificationData}');

      switch (purchaseDetails.status) {
        case PurchaseStatus.pending:
          _updateState(
            (c) => c.copyWith(
              isPurchasing: true,
              purchaseFlowStatus: IapPurchaseFlowStatus.pending,
              errorMessage: null,
            ),
          );
          break;
        case PurchaseStatus.error:
          _updateState(
            (c) => c.copyWith(
              isPurchasing: false,
              isRestoring: false,
              isRefreshing: false,
              purchaseFlowStatus: IapPurchaseFlowStatus.error,
              errorMessage: purchaseDetails.error?.message ??
                  'Unknown error occurred during purchase',
            ),
          );
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _markPurchased(
            purchaseDate:
                _parseTransactionDate(purchaseDetails.transactionDate),
            flowStatus: purchaseDetails.status == PurchaseStatus.purchased
                ? IapPurchaseFlowStatus.purchased
                : IapPurchaseFlowStatus.restored,
          );

          break;
        case PurchaseStatus.canceled:
          _updateState(
            (c) => c.copyWith(
              isPurchasing: false,
              isRestoring: false,
              purchaseFlowStatus: IapPurchaseFlowStatus.error,
              errorMessage: 'Purchase canceled',
            ),
          );
          break;
      }
      if (purchaseDetails.pendingCompletePurchase) {
        await _iapService.completePurchase(purchaseDetails);
      }
    }
  }

  Future<void> _markPurchased({
    required DateTime? purchaseDate,
    required IapPurchaseFlowStatus flowStatus,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final now = DateTime.now();
    _writePurchaseCache(true, now);

    final status = _deriveStatus(
      purchased: true,
      isOriginalUser: current.isOriginalUser,
      trialDaysLeft: current.trialDaysLeft,
    );

    _updateState(
      (c) => c.copyWith(
        status: status,
        purchaseDate: purchaseDate ?? c.purchaseDate,
        lastChecked: Prefs().iapLastCheckTime,
        isPurchasing: false,
        isRestoring: false,
        isRefreshing: false,
        purchaseFlowStatus: flowStatus,
        trialDaysLeft: _trialDaysLeft(c.trialStartDate),
      ),
    );
  }

  void _writePurchaseCache(bool purchased, DateTime timestamp) {
    Prefs().iapPurchaseStatus = purchased;
    Prefs().iapLastCheckTime = timestamp;
  }

  bool _isCacheFresh(DateTime lastCheck) {
    final diff = DateTime.now().difference(lastCheck).inMilliseconds.abs();
    return diff < IAPService.kMaxValidationInterval;
  }

  int _trialDaysLeft(DateTime? startDate) {
    if (startDate == null) return 0;
    final days = DateTime.now().difference(startDate).inDays.abs();
    final left = IAPService.kTrialDays - days;
    return left < 0 ? 0 : left;
  }

  IAPStatus _deriveStatus({
    required bool purchased,
    required bool isOriginalUser,
    required int trialDaysLeft,
  }) {
    if (purchased) {
      return IAPStatus.purchased;
    }
    if (isOriginalUser) {
      return IAPStatus.originalUser;
    }
    if (trialDaysLeft > 0) {
      return IAPStatus.trial;
    }
    return IAPStatus.trialExpired;
  }

  DateTime? _parseTransactionDate(String? transactionDate) {
    if (transactionDate == null) return null;
    try {
      final ms = int.parse(transactionDate);
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  void _updateState(IapState Function(IapState current) transform) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncValue.data(transform(current));
  }
}
