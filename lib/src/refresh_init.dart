import 'dart:async';

import 'package:flutter/material.dart';

/// Global Flutter presentation setup for session expiry.
///
/// Initialize once before dependency injection and pass [navigatorKey] to the
/// app's `MaterialApp` or `GetMaterialApp`.
final class RefreshInit {
  RefreshInit._();

  /// Shared session-expiry presenter used by default by interceptors.
  static final RefreshInit instance = RefreshInit._();

  /// Navigator key that must be assigned to the app's root navigator.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  Widget? _sessionExpiredWidget;
  bool _barrierDismissible = false;
  Color? _barrierColor;
  bool _dialogVisible = false;
  bool _presentationScheduled = false;

  /// Whether [initialize] has configured a session-expired widget.
  bool get isInitialized => _sessionExpiredWidget != null;

  /// Configures the widget displayed when any interceptor expires a session.
  ///
  /// Call this before dependency injection creates `RefreshInterceptor`
  /// instances that omit an explicit session-expired callback.
  ///
  /// [barrierDismissible] controls whether tapping outside closes the dialog.
  /// [barrierColor] overrides Flutter's default modal barrier color.
  /// Calling this again replaces the previous widget and dialog options.
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
  /// If the root navigator is not ready, presentation is retried after the
  /// next frame. Throws [StateError] when [initialize] was not called.
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
