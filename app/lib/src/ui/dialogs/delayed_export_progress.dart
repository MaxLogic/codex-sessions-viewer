import 'dart:async';

import 'package:flutter/material.dart';

/// Shows a modal progress bar only when an export is still running after two
/// seconds. The dialog is removed on success and failure alike.
Future<T> runWithDelayedExportProgress<T>(
  BuildContext context, {
  required String label,
  required Future<T> Function() operation,
}) async {
  BuildContext? dialogContext;
  var finished = false;
  final timer = Timer(const Duration(seconds: 2), () {
    if (finished || !context.mounted) return;
    unawaited(
      showDialog<void>(
        context: context,
        useRootNavigator: false,
        barrierDismissible: false,
        builder: (context) {
          dialogContext = context;
          return AlertDialog(
            title: Text(label),
            content: Semantics(
              liveRegion: true,
              label: '$label in progress',
              child: const SizedBox(
                width: 320,
                child: LinearProgressIndicator(),
              ),
            ),
          );
        },
      ),
    );
  });
  try {
    return await operation();
  } finally {
    finished = true;
    timer.cancel();
    void closeDialog() {
      final activeDialog = dialogContext;
      if (activeDialog != null && activeDialog.mounted) {
        Navigator.of(activeDialog).pop();
      }
    }

    if (dialogContext == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => closeDialog());
    } else {
      closeDialog();
    }
  }
}
