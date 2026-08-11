import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:refresh_interceptor/refresh_interceptor.dart';

Future<void> main() async {
  await RefreshInit.instance.initialize(
    sessionExpiredWidget: const _ExampleSessionExpiredDialog(),
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: RefreshInit.instance.navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  late final Dio _dio;
  late final MemoryTokenStore _tokens;
  late final FakeApiAdapter _api;
  final List<String> _events = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _tokens = MemoryTokenStore('expired-access', 'valid-refresh');
    _api = FakeApiAdapter();
    _dio = Dio()..httpClientAdapter = _api;
    RefreshInterceptor(
      tokenStore: _tokens,
      onRefresh: (refreshToken) async {
        _log('Refreshing with $refreshToken');
        await Future<void>.delayed(const Duration(milliseconds: 700));
        _api.refreshCalls++;
        return const RefreshTokens(
          accessToken: 'fresh-access',
          refreshToken: 'rotated-refresh',
        );
      },
    ).attachTo(_dio);
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() => _events.insert(0, message));
  }

  Future<void> _runDemo() async {
    setState(() {
      _running = true;
      _events.clear();
      _api.refreshCalls = 0;
      _tokens
        ..accessToken = 'expired-access'
        ..refreshToken = 'valid-refresh';
    });

    _log('Sending 3 protected requests together');
    try {
      final responses = await Future.wait([
        _dio.get<Map<String, dynamic>>('/profile/1'),
        _dio.get<Map<String, dynamic>>('/profile/2'),
        _dio.get<Map<String, dynamic>>('/profile/3'),
      ]);
      _log('${responses.length} requests succeeded');
      _log('Refresh HTTP calls: ${_api.refreshCalls}');
      _log('Stored refresh token: ${_tokens.refreshToken}');
    } on DioException catch (error) {
      _log('Request failed: ${error.message}');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Refresh interceptor demo')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Three requests start with an expired token. They share one '
              'refresh, save rotated tokens, then retry automatically.',
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _running ? null : _runDemo,
              icon: _running
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: const Text('Run concurrent requests'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: RefreshInit.instance.showSessionExpired,
              child: const Text('Show session-expired widget'),
            ),
            const SizedBox(height: 24),
            Text('Event log', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: Card(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _events.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (_, index) => Text(_events[index]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExampleSessionExpiredDialog extends StatelessWidget {
  const _ExampleSessionExpiredDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Session expired'),
      content: const Text('Please sign in again to continue.'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

final class MemoryTokenStore implements TokenStore {
  MemoryTokenStore(this.accessToken, this.refreshToken);

  String? accessToken;
  String? refreshToken;

  @override
  Future<String?> readAccessToken() async => accessToken;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    this.accessToken = accessToken;
    if (refreshToken != null) this.refreshToken = refreshToken;
  }

  @override
  Future<void> clearTokens() async {
    accessToken = null;
    refreshToken = null;
  }
}

final class FakeApiAdapter implements HttpClientAdapter {
  int refreshCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final token = options.headers['Authorization'];
    if (token != 'Bearer fresh-access') {
      return _json({'code': 'token_expired'}, 401);
    }
    return _json({'path': options.path, 'name': 'Ada'}, 200);
  }

  ResponseBody _json(Object value, int statusCode) => ResponseBody.fromString(
        jsonEncode(value),
        statusCode,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
