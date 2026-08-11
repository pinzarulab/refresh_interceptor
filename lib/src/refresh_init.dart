import 'dart:async';

import 'package:flutter/material.dart';

/// Global Flutter presentation setup for session expiry.
///
/// Initialize once before dependency injection and pass [navigatorKey] to the
/// app's `MaterialApp` or `GetMaterialApp`.
final class RefreshInit {
  RefreshInit._();

  static final RefreshInit instance = RefreshInit._();

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  Widget? _sessionExpiredWidget;
  bool _barrierDismissible = false;
  Color? _barrierColor;
  bool _dialogVisible = false;
  bool _presentationScheduled = false;

  bool get isInitialized => _sessionExpiredWidget != null;

  /// Configures the widget displayed when any interceptor expires a session.
  Future<void> initialize({
    required Widget sessionExpiredWidget,
    bool barrierDismissible = false,
    Color? barrierColor,
  }) async {
    _sessionExpiredWidget = sessionExpiredWidget;
    _barrierDismissible = barrierDismissible;
    _barrierColor = barrierColor;
    _dialogVisible = false;
    _presentationScheduled = false;
  }

  /// Shows configured widget once. Concurrent calls are deduplicated.
  ///
  /// Does not wait for dialog closure, so user interaction never blocks Dio.
  void showSessionExpired() {
    final widget = _sessionExpiredWidget;
    if (widget == null) {
      throw StateError(
        'RefreshInit is not initialized. Call '
        'RefreshInit.instance.initialize() before creating interceptors.',
      );
    }
    if (_dialogVisible) return;

    final context = navigatorKey.currentContext;
    if (context == null) {
      _schedulePresentation();
      return;
    }

    _dialogVisible = true;
    unawaited(
      showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: _barrierDismissible,
        barrierColor: _barrierColor,
        builder: (_) => widget,
      ).whenComplete(() {
        _dialogVisible = false;
      }),
    );
  }

  void _schedulePresentation() {
    if (_presentationScheduled) return;
    _presentationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _presentationScheduled = false;
      showSessionExpired();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}
