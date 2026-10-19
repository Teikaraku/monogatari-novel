import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

class AnxToast {
  static FToast fToast = FToast();

  static void init(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      fToast.init(context);
    });
  }

  /// A dark translucent capsule above the bottom edge; replaces any toast still showing.
  static void show(String message, {Icon? icon, int duration = 2000}) {
    final toast = Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xE6242426),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 16, offset: Offset(0, 4))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            IconTheme.merge(data: const IconThemeData(color: Colors.white, size: 18), child: icon),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.35),
            ),
          ),
        ],
      ),
    );

    fToast.removeQueuedCustomToasts();
    fToast.showToast(
      child: toast,
      gravity: ToastGravity.BOTTOM,
      toastDuration: Duration(milliseconds: duration),
    );
  }
}
