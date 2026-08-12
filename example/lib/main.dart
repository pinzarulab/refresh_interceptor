import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:refresh_interceptor/refresh_interceptor.dart';

const _apiBaseUrl = String.fromEnvironment(
  'SESSION_API_URL',
  defaultValue: 'http://127.0.0.1:8080',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  late final Dio _authDio;
  late final Dio _appDio;
  late final MemoryTokenStore _tokens;
  late final RefreshInterceptor _refreshInterceptor;

  final List<String> _events = [];
  bool _running = false;
  int _refreshCalls = 0;

  @override
  void initState() {
    super.initState();
    final options = BaseOptions(
      baseUrl: _apiBaseUrl,
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
    );
    _authDio = Dio(options);
    _appDio = Dio(options);
    _tokens = MemoryTokenStore();
    _refreshInterceptor = RefreshInterceptor(
      readAccessToken: _tokens.readAccessToken,
      readRefreshToken: _tokens.readRefreshToken,
      saveTokens: _tokens.updateTokens,
      clearTokens: _tokens.clearTokens,
      onRefresh: (refreshToken) async {
        _refreshCalls++;
        _log('POST /refresh/');
        final response = await _authDio.post<Map<String, dynamic>>(
          '/refresh/',
          data: {'refresh_token': refreshToken},
        );
        final data = response.data!;
        return RefreshTokens(
          accessToken: data['access_token'] as String,
          refreshToken: data['refresh_token'] as String?,
        );
      },
      rejectIfTokenMissing: true,
      onError: (error, _) => _log('Interceptor error: $error'),
    )..attachToAll([_appDio]);
  }

  @override
  void dispose() {
    _refreshInterceptor.detachFrom(_appDio);
    _authDio.close(force: true);
    _appDio.close(force: true);
    super.dispose();
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() => _events.insert(0, message));
  }

  Future<void> _prepareExpiredAccessSession() async {
    await _authDio.post<void>('/test/reset');
    final response = await _authDio.post<Map<String, dynamic>>(
      '/login/',
      data: const {
        'email': 'user@example.com',
        'password': 'password123',
      },
    );
    final data = response.data!;
    _refreshInterceptor.resetSession();
    await _tokens.updateTokens(
      data['access_token'] as String,
      data['refresh_token'] as String?,
    );
    _log('POST /login/ → stored expired access token');
  }

  Future<void> _runSuccessfulRefresh() => _run('Successful refresh', () async {
        await _prepareExpiredAccessSession();
        _log('Sending 3 concurrent GET /profile/ requests');
        final responses = await Future.wait(
          List.generate(
            3,
            (_) => _appDio.get<Map<String, dynamic>>('/profile/'),
          ),
        );
        _log('${responses.length} profile requests succeeded');
        _log('Refresh HTTP calls: $_refreshCalls');
        _log('Stored access: ${_tokens.accessToken}');
        _log('Stored refresh: ${_tokens.refreshToken}');
      });

  Future<void> _runPermanentExpiry() => _run('Permanent expiry', () async {
        await _prepareExpiredAccessSession();
        await _authDio.post<void>('/test/expire-session');
        _log('Server configured to reject access and refresh tokens');
        try {
          await _appDio.get<Map<String, dynamic>>('/profile/');
        } on DioException catch (error) {
          _log('Final profile status: ${error.response?.statusCode}');
          _log('Stored tokens cleared: ${_tokens.accessToken == null}');
        }
      });

  Future<void> _run(String name, Future<void> Function() operation) async {
    setState(() {
      _running = true;
      _events.clear();
      _refreshCalls = 0;
    });
    _log('$name started against $_apiBaseUrl');
    try {
      await operation();
    } on DioException catch (error) {
      _log('Request failed: ${error.message}');
      _log('Is the Dart server running at $_apiBaseUrl?');
    } catch (error) {
      _log('Unexpected error: $error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Refresh interceptor demo')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Session API: $_apiBaseUrl'),
              const SizedBox(height: 8),
              const Text(
                'Start tool/session_api_server.dart, then run either scenario.',
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _running ? null : _runSuccessfulRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Run successful refresh'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _running ? null : _runPermanentExpiry,
                icon: const Icon(Icons.lock_clock),
                label: const Text('Run permanent expiry'),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text(
                    'Event log',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (_running)
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Card(
                  child: _events.isEmpty
                      ? const Center(child: Text('Run a scenario to begin.'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _events.length,
                          separatorBuilder: (_, __) => const Divider(),
                          itemBuilder: (_, index) => SelectableText(
                            _events[index],
                          ),
                        ),
                ),
              ),
            ],
          ),
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
      content: const Text(
        'The refresh token was rejected. Stored tokens were cleared.',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

final class MemoryTokenStore {
  String? accessToken;
  String? refreshToken;

  Future<String?> readAccessToken() async => accessToken;

  Future<String?> readRefreshToken() async => refreshToken;

  Future<void> updateTokens(
    String accessToken,
    String? refreshToken,
  ) async {
    this.accessToken = accessToken;
    if (refreshToken != null) this.refreshToken = refreshToken;
  }

  Future<void> clearTokens() async {
    accessToken = null;
    refreshToken = null;
  }
}
