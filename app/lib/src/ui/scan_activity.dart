import 'dart:async';

import 'package:flutter/foundation.dart';

import 'screens/sessions_screen.dart';

/// App-owned scan state. Views may come and go without owning its lifetime.
class ScanActivity extends ChangeNotifier {
  SessionsRefreshOperation? operation;
  bool forced = false;
  bool cancelling = false;
  String status = '';
  String announcement = '';
  SessionsRefreshProgress? progress;
  DateTime? _lastAnnouncement;
  bool _disposed = false;

  bool get running => operation != null;

  void start(SessionsRefreshOperation value, {required bool force}) {
    operation = value;
    forced = force;
    cancelling = false;
    progress = null;
    status = force
        ? 'Reparse started. Scanning sessions...'
        : 'Scanning sessions...';
    announcement = status;
    _lastAnnouncement = DateTime.now();
    _notify();
  }

  void update(SessionsRefreshProgress value) {
    progress = value;
    if (!cancelling) {
      status = value.statusMessage;
      final now = DateTime.now();
      if (_lastAnnouncement == null ||
          now.difference(_lastAnnouncement!) >= const Duration(seconds: 5)) {
        announcement = status;
        _lastAnnouncement = now;
      }
    }
    _notify();
  }

  void finish(String message) {
    operation = null;
    cancelling = false;
    status = message;
    announcement = message;
    _notify();
  }

  Future<void> cancel() async {
    final active = operation;
    if (active == null || cancelling) return;
    cancelling = true;
    status = announcement = 'Cancelling scan...';
    _notify();
    try {
      await active.cancel();
    } on Object catch (error) {
      cancelling = false;
      status = announcement = 'Could not cancel the scan. Details: $error';
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
