import 'dart:async';
import 'dart:convert';

import 'package:anx_reader/service/iap/base_iap_service.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:asn1lib/asn1lib.dart';
// import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';

class AppStoreIAPService extends BaseIAPService {
  AppStoreIAPService({
    required super.trialDays,
  })  : _inAppPurchase = InAppPurchase.instance,
        _parsedReceipt = {
          'receipt': <String, dynamic>{
            'in_app': [],
          },
          'environment': 'Sandbox',
          'status': 0,
        };
  final InAppPurchase _inAppPurchase;
  Map<String, dynamic> _parsedReceipt;
  final String _productId = 'anx_reader_lifetime';

  /// Track if receipt refresh has failed, so we can fall back to cache
  bool _receiptRefreshFailed = false;
  bool get receiptRefreshFailed => _receiptRefreshFailed;

  List<String> originalUserVersions = [
    '1.4.0',
    '1.4.1',
    '1.4.2',
    '2077',
    '2084',
    '2086',
    '2092',
  ];
  @override
  String get storeName => 'App Store';

  @override
  String get productId => _productId;

  @override
  Stream<List<PurchaseDetails>> get purchaseUpdates =>
      _inAppPurchase.purchaseStream;

  @override
  Future<ProductDetailsResponse> queryProductDetails() async {
    final Set<String> productIds = {productId};
    return _inAppPurchase.queryProductDetails(productIds);
  }

  @override
  Future<void> buy(ProductDetails productDetails) async {
    final paymentWrapper = SKPaymentQueueWrapper();
    final transactions = await paymentWrapper.transactions();
    await Future.wait(transactions
        .map((transaction) => paymentWrapper.finishTransaction(transaction)));

    final purchaseParam = PurchaseParam(productDetails: productDetails);
    await _inAppPurchase.buyNonConsumable(purchaseParam: purchaseParam);
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchaseDetails) {
    return _inAppPurchase.completePurchase(purchaseDetails);
  }

  @override
  Future<void> restorePurchases() async {
    AnxLog.info('IAP: Starting restore purchases');

    // Clear any pending transactions that might be blocking the restore
    try {
      final paymentWrapper = SKPaymentQueueWrapper();
      final transactions = await paymentWrapper.transactions();
      if (transactions.isNotEmpty) {
        AnxLog.info(
            'IAP: Clearing ${transactions.length} pending transaction(s) before restore');
        await Future.wait(
          transactions.map(
              (transaction) => paymentWrapper.finishTransaction(transaction)),
        );
      }
    } catch (e) {
      AnxLog.warning('IAP: Error clearing pending transactions: $e');
      // Continue with restore even if clearing fails
    }

    return _inAppPurchase.restorePurchases();
  }

  @override
  Future<bool> isAvailable() {
    return _inAppPurchase.isAvailable();
  }

  @override
  Future<void> initialize() async {
    await _loadReceipt();
  }

  @override
  Future<IapPlatformSnapshot> loadSnapshot() async {
    await _loadReceipt();

    final hasPurchase = _hasActivePurchase(_parsedReceipt);
    final purchaseDate = _extractPurchaseDate(_parsedReceipt);
    final originalDate = _getOriginalDate(_parsedReceipt);
    final originalUser = _isOriginalUser(_parsedReceipt);

    return IapPlatformSnapshot(
      hasPurchase: hasPurchase,
      // If receipt refresh failed, we can't reliably determine purchase status
      isPurchaseStatusReliable: !_receiptRefreshFailed,
      trialStartDate: originalDate,
      purchaseDate: purchaseDate,
      isOriginalUser: originalUser,
      receiptRefreshFailed: _receiptRefreshFailed,
    );
  }

  Future<void> _loadReceipt() async {
    try {
      final receiptBase64 = await _getReceiptBase64();
      if (receiptBase64.isEmpty) {
        AnxLog.warning('IAP: Empty receipt during initialization');
        return;
      }

      _parsedReceipt = _parseReceiptLocally(receiptBase64);

      AnxLog.info('IAP: receipt loaded, $_parsedReceipt');
    } catch (e) {
      AnxLog.severe('IAP: Error loading receipt: $e');
    }
  }

  Future<String> _getReceiptBase64({int retryCount = 0}) async {
    const maxRetries = 2;

    try {
      final iosPlatformAddition = _inAppPurchase
          .getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>();
      final receiptBase64 =
          await iosPlatformAddition.refreshPurchaseVerificationData();

      if (receiptBase64?.localVerificationData.isNotEmpty == true) {
        _receiptRefreshFailed = false;
        return receiptBase64!.localVerificationData;
      }

      // Empty receipt but no exception - might be first install without purchase
      AnxLog.info('IAP: Receipt refresh returned empty data');
      return '';
    } catch (e) {
      AnxLog.severe(
          'IAP: Error getting receipt base64 (attempt ${retryCount + 1}): $e');

      // Retry with exponential backoff
      if (retryCount < maxRetries) {
        final delay = Duration(milliseconds: 500 * (retryCount + 1));
        AnxLog.info(
            'IAP: Retrying receipt refresh after ${delay.inMilliseconds}ms');
        await Future.delayed(delay);
        return _getReceiptBase64(retryCount: retryCount + 1);
      }

      // All retries failed, mark as failed so we can fall back to cache
      _receiptRefreshFailed = true;
      AnxLog.warning(
          'IAP: Receipt refresh failed after $maxRetries retries, will trust cache');
      return '';
    }
  }

  // Future<Map<String, dynamic>> parseReceiptViaServer(
  //     String receiptBase64) async {
  //   Future<Map<String, dynamic>> verifyReceipt(
  //       String receiptData, bool isSandbox) async {
  //     final url = isSandbox
  //         ? 'https://sandbox.itunes.apple.com/verifyReceipt'
  //         : 'https://buy.itunes.apple.com/verifyReceipt';

  //     final body = {
  //       'receipt-data': receiptData,
  //       'exclude-old-transactions': true,
  //     };

  //     final response = await http.post(
  //       Uri.parse(url),
  //       body: jsonEncode(body),
  //       headers: {'Content-Type': 'application/json'},
  //     );

  //     if (response.statusCode != 200) {
  //       throw Exception('Failed to verify receipt: ${response.statusCode}');
  //     }

  //     return jsonDecode(response.body);
  //   }

  //   Map<String, dynamic> handleReceiptResponse(Map<String, dynamic> response) {
  //     AnxLog.info('IAP: handleReceiptResponse: $response');
  //     final status = response['status'];
  //     if (status == 0) {
  //       return response['receipt'];
  //     }
  //     throw Exception('Failed to verify receipt: $status');
  //   }

  //   try {
  //     final productionResponse = await verifyReceipt(receiptBase64, false);

  //     if (productionResponse['status'] == 21007) {
  //       final sandboxResponse = await verifyReceipt(receiptBase64, true);
  //       return handleReceiptResponse(sandboxResponse);
  //     } else {
  //       return handleReceiptResponse(productionResponse);
  //     }
  //   } catch (e) {
  //     AnxLog.severe('IAP: Server verification error: $e');
  //     rethrow;
  //   }
  // }

  Map<String, dynamic> _parseReceiptLocally(String receipt) {
    DateTime formatDate(String isoDate) {
      try {
        return DateTime.parse(isoDate);
      } catch (e) {
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    String formatDatePST(String isoDate) {
      return formatDate(isoDate)
          .toLocal()
          .toIso8601String()
          .replaceAll('T', ' ')
          .replaceAll('Z', '')
          .replaceAll(' ', 'PST');
    }

    String getMillisFromDate(String isoDate) {
      return formatDate(isoDate).toLocal().millisecondsSinceEpoch.toString();
    }

    String getFieldValue(ASN1Object obj) {
      final parser = ASN1Parser(obj.valueBytes());
      if (!parser.hasNext()) {
        return '';
      }
      dynamic value;
      try {
        value = parser.nextObject();
      } catch (e) {
        return '';
      }

      if (value is ASN1UTF8String) {
        return value.utf8StringValue;
      } else if (value is ASN1Integer) {
        return value.intValue.toString();
      } else if (value is ASN1IA5String) {
        return value.stringValue;
      } else {
        return value.toString();
      }
    }

    void parseReceipt(ASN1Set set, Map<String, dynamic> result) {
      void parseInAppPurchase(ASN1Parser parser, Map<String, dynamic> result) {
        void parseInappPurchaseField(
            ASN1Sequence fieldSeq, Map<String, dynamic> purchase) {
          if (fieldSeq.elements.length >= 3) {
            final element0 = fieldSeq.elements[0];
            var fieldType = 0;
            if (element0 is ASN1Integer) {
              fieldType = element0.intValue;
            }
            final fieldValue = fieldSeq.elements[2];
            final value = getFieldValue(fieldValue);

            switch (fieldType) {
              case 1701:
                purchase['quantity'] = value;
                break;
              case 1702:
                purchase['product_id'] = value;
                break;
              case 1703:
                purchase['transaction_id'] = value;
                break;
              case 1705:
                purchase['original_transaction_id'] = value;
                break;
              case 1704:
                purchase['purchase_date'] = formatDate(value);
                purchase['purchase_date_ms'] = getMillisFromDate(value);
                purchase['purchase_date_pst'] = formatDatePST(value);
                break;
              case 1706:
                purchase['original_purchase_date'] = formatDate(value);
                purchase['original_purchase_date_ms'] =
                    getMillisFromDate(value);
                purchase['original_purchase_date_pst'] = formatDatePST(value);
                break;
            }
          }
        }

        Map<String, dynamic> purchase = {};

        while (parser.hasNext()) {
          final obj = parser.nextObject();
          final List<ASN1Object> set = (obj as ASN1Set).elements.toList();
          for (final field in set) {
            if (field is ASN1Sequence) {
              try {
                parseInappPurchaseField(field, purchase);
              } catch (e) {
                AnxLog.severe('IAP: Error parsing in-app purchase field: $e');
              }
            }
          }

          if (purchase.isNotEmpty) {
            purchase['in_app_ownership_type'] = 'PURCHASED';
            result['receipt']['in_app'].add(purchase);
          }
        }
      }

      void extractFieldValue(
          ASN1Sequence fieldSeq, Map<String, dynamic> result) {
        if (fieldSeq.elements.length < 3) return;

        final element0 = fieldSeq.elements[0];
        var fieldType = 0;

        if (element0 is ASN1Integer) {
          fieldType = element0.intValue;
        }
        final fieldValue = fieldSeq.elements[2];

        if (fieldType == 17 && fieldValue is ASN1OctetString) {
          try {
            parseInAppPurchase(ASN1Parser(fieldValue.valueBytes()), result);
          } catch (e) {
            AnxLog.severe('IAP: Error parsing in-app purchase: $e');
          }
          return;
        }

        final value = getFieldValue(fieldValue);

        switch (fieldType) {
          case 2:
            result['receipt']['bundle_id'] = value;
            break;
          case 3:
            result['receipt']['application_version'] = value;
            break;
          case 0:
            result['receipt']['receipt_type'] = value;
            if (value.contains('Sandbox')) {
              result['environment'] = 'Sandbox';
            } else {
              result['environment'] = 'Production';
            }
            break;
          case 12:
            result['receipt']['receipt_creation_date'] = formatDate(value);
            result['receipt']['receipt_creation_date_ms'] =
                getMillisFromDate(value);
            result['receipt']['receipt_creation_date_pst'] =
                formatDatePST(value);
            break;
          case 18:
            result['receipt']['original_purchase_date'] = formatDate(value);
            result['receipt']['original_purchase_date_ms'] =
                getMillisFromDate(value);
            result['receipt']['original_purchase_date_pst'] =
                formatDatePST(value);
            break;
          case 19:
            result['receipt']['original_application_version'] = value;
            break;
        }
      }

      for (final field in set.elements) {
        if (field is ASN1Sequence) {
          try {
            extractFieldValue(field, result);
          } catch (e) {
            AnxLog.severe('IAP: Error extracting field value: $e');
          }
        }
      }
    }

    final receiptData = base64.decode(receipt);
    final parser = ASN1Parser(receiptData);

    Map<String, dynamic> result = {
      'receipt': <String, dynamic>{
        'in_app': [],
      },
      'environment': 'Sandbox',
      'status': 0,
    };

    final ASN1Sequence contentInfo = parser.nextObject() as ASN1Sequence;
    final ASN1Object content = contentInfo.elements[1];
    final ASN1Sequence signedData =
        ASN1Parser(content.valueBytes()).nextObject() as ASN1Sequence;
    final ASN1Sequence encapContentInfo =
        signedData.elements[2] as ASN1Sequence;
    final ASN1Object eContent = encapContentInfo.elements[1];
    final ASN1OctetString octetString =
        ASN1Parser(eContent.valueBytes()).nextObject() as ASN1OctetString;
    final ASN1Set set =
        ASN1Parser(octetString.valueBytes()).nextObject() as ASN1Set;

    try {
      parseReceipt(set, result);
    } catch (e) {
      AnxLog.severe('IAP: Error parsing receipt fields: $e');
    }

    return result;
  }

  bool _isOriginalUser([Map<String, dynamic>? receipt]) {
    try {
      final r = receipt ?? _parsedReceipt;
      final originalUserVersion = r['receipt']['original_application_version'];

      if (originalUserVersion != null &&
          originalUserVersions.contains(originalUserVersion.toString())) {
        return true;
      }
      return false;
    } catch (e) {
      AnxLog.severe('IAP: Error checking original user: $e');
      return false;
    }
  }

  DateTime _getOriginalDate([Map<String, dynamic>? receipt]) {
    final r = receipt ?? _parsedReceipt;
    final originalDate = r['receipt']['original_purchase_date'];
    if (originalDate == null || originalDate is! DateTime) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    return originalDate;
  }

  bool _hasActivePurchase(Map<String, dynamic> receipt) {
    try {
      final inApp = receipt['receipt']?['in_app'];
      return inApp != null && inApp.isNotEmpty;
    } catch (e) {
      AnxLog.severe('IAP: Error checking active purchase: $e');
      return false;
    }
  }

  DateTime? _extractPurchaseDate(Map<String, dynamic> receipt) {
    try {
      final inApp = receipt['receipt']?['in_app'];
      if (inApp != null && inApp.isNotEmpty) {
        return inApp.first['purchase_date'] as DateTime?;
      }
      return null;
    } catch (e) {
      AnxLog.severe('IAP: Error getting purchase date: $e');
      return null;
    }
  }
}
