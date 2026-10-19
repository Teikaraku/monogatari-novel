import 'package:anx_reader/monogatari/theme.dart';
import 'package:flutter/material.dart';

/// Centered icon, bold title, secondary line and an optional text action, for empty and error states.
class MgEmptyState extends StatelessWidget {
  const MgEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? description;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 62, color: palette.secondaryLabel),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
            ),
            if (description != null && description!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 16, height: 1.5, color: palette.secondaryLabel),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: onAction,
                child: Text(action!,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
