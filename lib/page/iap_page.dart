import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/iap_state.dart';
import 'package:anx_reader/service/iap/iap_service.dart';
import 'package:anx_reader/providers/iap.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/widgets/common/container/filled_container.dart';
// import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

class IAPPage extends ConsumerWidget {
  const IAPPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final iapAsync = ref.watch(iapProvider);

    return iapAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(
          title: Text(L10n.of(context).iapPageTitle),
        ),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (error, s) {
        AnxLog.severe('IAP: Error loading IAP state: $error', s);

        return Scaffold(
          appBar: AppBar(
            title: Text(L10n.of(context).iapPageTitle),
          ),
          body: Center(child: Text(error.toString())),
        );
      },
      data: (iapState) => Scaffold(
        appBar: AppBar(
          title: Text(L10n.of(context).iapPageTitle),
          actions: [
            TextButton(
              onPressed: () => ref.read(iapProvider.notifier).restore(),
              child: Text(L10n.of(context).iapPageRestore),
            ),
          ],
        ),
        body: _buildContent(context, ref, iapState),
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref, IapState state) {
    final notifier = ref.read(iapProvider.notifier);
    final List<Map<String, dynamic>> content = [
      {
        'icon': Icons.auto_awesome,
        'title': L10n.of(context).iapPageFeatureAi,
        'desc': L10n.of(context).iapPageFeatureAiDesc,
      },
      {
        'icon': Icons.sync,
        'title': L10n.of(context).iapPageFeatureSync,
        'desc': L10n.of(context).iapPageFeatureSyncDesc,
      },
      {
        'icon': Icons.bar_chart,
        'title': L10n.of(context).iapPageFeatureStats,
        'desc': L10n.of(context).iapPageFeatureStatsDesc,
      },
      {
        'icon': Icons.color_lens,
        'title': L10n.of(context).iapPageFeatureCustom,
        'desc': L10n.of(context).iapPageFeatureCustomDesc,
      },
      {
        'icon': Icons.note,
        'title': L10n.of(context).iapPageFeatureNote,
        'desc': L10n.of(context).iapPageFeatureNoteDesc,
      },
      {
        'icon': Icons.more_horiz,
        'title': L10n.of(context).iapPageFeatureRich,
        'desc': L10n.of(context).iapPageFeatureRichDesc,
      },
    ];

    final isBusy =
        state.isPurchasing || state.isRestoring || state.isRefreshing;
    final priceText =
        state.products.isNotEmpty ? state.products.first.price : '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildStatusCard(context, state),
                  const SizedBox(height: 20),
                  Text(
                    L10n.of(context).iapPageWhyChoose,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(builder: (context, constraints) {
                    return Wrap(
                      children: content
                          .map((item) => SizedBox(
                                width: constraints.maxWidth /
                                    (constraints.maxWidth ~/ 400),
                                child: _buildFeatureItem(
                                  context,
                                  item['icon'],
                                  item['title'],
                                  item['desc'],
                                ),
                              ))
                          .toList(),
                    );
                  }),
                  const SizedBox(height: 30),
                  if (AnxPlatform.isMacOS || AnxPlatform.isIOS)
                    Text(L10n.of(context).iapPageRestoreHint),
                  if (AnxPlatform.isAndroid)
                    Text(L10n.of(context).iapPageRestoreHintPlayStore),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        child: Text(L10n.of(context).aboutPrivacyPolicy),
                        onPressed: () async {
                          launchUrl(
                            Uri.parse('https://anx.anxcye.com/privacy.html'),
                            mode: LaunchMode.externalApplication,
                          );
                        },
                      ),
                      TextButton(
                        child: Text(L10n.of(context).aboutTermsOfUse),
                        onPressed: () async {
                          launchUrl(
                            Uri.parse('https://anx.anxcye.com/terms.html'),
                            mode: LaunchMode.externalApplication,
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!state.isPurchased && state.isAvailable) ...[
                Padding(
                  padding: const EdgeInsets.all(10.0),
                  child: Text(
                    L10n.of(context).iapPageLifetimeHint(
                        state.products.isEmpty ? '' : priceText),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                SafeArea(
                  bottom: state.errorMessage?.isEmpty ?? true,
                  minimum: EdgeInsets.only(
                      bottom: state.errorMessage?.isEmpty ?? true ? 20 : 0),
                  child: ElevatedButton(
                    onPressed: isBusy ? null : notifier.buy,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: isBusy
                        ? Center(
                            child: CircularProgressIndicator(
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          )
                        : Text(
                            L10n.of(context).iapPageOneTimePurchase,
                            style: const TextStyle(
                                fontSize: 18, color: Colors.white),
                          ),
                  ),
                ),
              ],
              if (state.errorMessage != null && state.errorMessage!.isNotEmpty)
                SafeArea(
                  minimum: const EdgeInsets.only(bottom: 20),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 20.0),
                    child: Text(
                      state.errorMessage!,
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(BuildContext context, IapState state) {
    Color cardColor;
    IconData statusIcon;
    String statusDescription;
    String? timeInfo;

    switch (state.status) {
      case IAPStatus.purchased:
        statusIcon = Icons.verified;
        statusDescription = L10n.of(context).iapPageStatusPurchased;
        cardColor = Colors.green;
        if (state.purchaseDate != null) {
          timeInfo = L10n.of(context).iapPageDatePurchased(
            _formatDate(state.purchaseDate!),
          );
        }
        break;
      case IAPStatus.trial:
        statusIcon = Icons.access_time;
        statusDescription =
            L10n.of(context).iapPageStatusTrial(state.trialDaysLeft.toString());
        cardColor = Colors.blue;
        if (state.trialStartDate != null &&
            state.trialStartDate!.millisecondsSinceEpoch > 0) {
          timeInfo = L10n.of(context).iapPageDateTrialStart(
            _formatDate(state.trialStartDate!),
          );
        }
        break;
      case IAPStatus.trialExpired:
        statusIcon = Icons.timer_off;
        statusDescription = L10n.of(context).iapPageStatusTrialExpired;
        cardColor = Colors.orange;
        if (state.trialStartDate != null &&
            state.trialStartDate!.millisecondsSinceEpoch > 0) {
          timeInfo = L10n.of(context).iapPageDateTrialStart(
            _formatDate(state.trialStartDate!),
          );
        }
        break;
      case IAPStatus.originalUser:
        statusIcon = Icons.stars;
        statusDescription = L10n.of(context).iapPageStatusOriginal;
        cardColor = Colors.purple;
        if (state.trialStartDate != null &&
            state.trialStartDate!.millisecondsSinceEpoch > 0) {
          timeInfo = L10n.of(context).iapPageDateOriginal(
            _formatDate(state.trialStartDate!),
          );
        }
        break;
      case IAPStatus.unknown:
        statusIcon = Icons.help_outline;
        statusDescription = L10n.of(context).iapPageStatusUnknown;
        cardColor = Colors.grey;
        break;
    }

    return FilledContainer(
      color: cardColor.withAlpha(30),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Icon(
              statusIcon,
              size: 50,
              color: Theme.of(context).primaryColor,
            ),
            const SizedBox(height: 10),
            Text(
              state.status.title(context),
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              statusDescription,
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            if (timeInfo != null) ...[
              const SizedBox(height: 5),
              Text(
                timeInfo,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (state.status == IAPStatus.trial)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: LinearProgressIndicator(
                  value: state.trialDaysLeft / IAPService.kTrialDays,
                  backgroundColor: Colors.grey.shade300,
                  valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).primaryColor),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return date.toIso8601String().substring(0, 10);
  }

  Widget _buildFeatureItem(
      BuildContext context, IconData icon, String title, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 30, color: Theme.of(context).primaryColor),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
