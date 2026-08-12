# refresh_interceptor

Shared token refresh for Dio. One setup works with one or many authenticated
Dio clients.

## What it handles

- Adds access tokens to requests.
- Shares one refresh across concurrent requests and Dio clients.
- Retries each failed request once with newest token.
- Supports refresh-token rotation.
- Prevents refresh loops.
- Emits session expiry once per login session.
- Detects a newly stored login token automatically.
- Supports custom auth schemes, expiry rules, and public routes.
- Has no service-locator or state-management dependency.

## Setup

Create one `RefreshInterceptor` for the authenticated session. Use a separate
Dio client for refresh calls so refresh never intercepts itself:

```dart
final apiDio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
final refreshDio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

final auth = RefreshInterceptor(
  readAccessToken: authLocal.getAccessToken,
  readRefreshToken: authLocal.getRefreshToken,
  saveTokens: authLocal.updateTokens,
  clearTokens: authLocal.clearTokens,
  onRefresh: (refreshToken) async {
    final response = await refreshDio.post<Map<String, dynamic>>(
      '/authorization/token/refresh/',
      data: {'refresh': refreshToken},
    );
    final data = response.data!;
    return RefreshTokens(
      accessToken: data['access'] as String,
      refreshToken: data['refresh'] as String?,
    );
  },
  onSessionExpired: () {
    // Reset app state or navigate to login.
  },
);

auth.attachTo(apiDio);
```

## Session-expired widget

Flutter apps can initialize the optional UI presenter in `main` and provide
their own dialog widget:

```dart
Future<void> main() async {
  await RefreshInit.instance.initialize(
    sessionExpiredWidget: const SessionExpiredDialog(),
  );
  await initDI(get: GetIt.instance);
  runApp(const MyApp());
}
```

Use the same navigator key on `MaterialApp` or `GetMaterialApp`:

```dart
MaterialApp(
  navigatorKey: RefreshInit.instance.navigatorKey,
  // ...
)
```

`RefreshInterceptor` uses this presenter when `onSessionExpired` is omitted.
Presenter deduplicates concurrent expiry events and does not block Dio while
user interacts with dialog. Explicit callbacks remain supported.

For multiple authenticated clients, attach the same instance:

```dart
auth.attachToAll([
  appDio,
  insuranceDio,
  notificationDio,
]);
```

All clients now share one in-flight refresh. This matters when servers rotate
refresh tokens.

## Token storage callbacks

Pass existing storage methods directly. They should match this API:

```dart
Future<String?> getAccessToken();
Future<String?> getRefreshToken();
Future<void> updateTokens(String accessToken, String? refreshToken);
Future<void> clearTokens();
```

## Configuration

Default header is `Authorization: Bearer <token>`. Change scheme:

```dart
final auth = RefreshInterceptor(
  // ...
  tokenPrefix: 'Token',
);
```

Customize protected routes and expiry detection:

```dart
final auth = RefreshInterceptor(
  // ...
  shouldAttachToken: (request) => !request.path.startsWith('/public/'),
  shouldRefresh: (error) {
    final data = error.response?.data;
    return error.response?.statusCode == 401 ||
        data is Map && data['code'] == 'token_expired';
  },
  rejectIfTokenMissing: true,
  expireSessionOnMissingToken: false,
  clearTokensOnRefreshFailure: false,
  onError: (error, stackTrace) {
    logger.error('Auth interceptor error', error, stackTrace);
  },
);
```

Missing tokens usually mean user is already logged out, so rejecting a request
does not show session-expired UI by default. Set
`expireSessionOnMissingToken: true` only when missing storage must be treated as
an expired active session.

## Session lifecycle

Session-expiry callback fires once for concurrent failures. When a new access
token appears after login, expiry state resets automatically. Call
`auth.resetSession()` before replacing stored tokens during login, logout, or
account switching. This prevents a refresh started by the previous session from
overwriting the new one.

## Refresh failure semantics

Return `null` from `onRefresh` when the server permanently rejects the refresh
token. The interceptor then clears tokens, according to
`clearTokensOnRefreshFailure`, and reports session expiry.

A `DioException` from `onRefresh` that matches `shouldRefresh` is handled the
same way. For example, refresh endpoint 401 automatically expires the session.

Throw for temporary failures such as timeouts, connection errors, and server
errors. These failures are sent to `onError`; stored tokens remain intact and
the session is not expired. The original request error continues to its caller.

## Proactive refresh and detach

```dart
final success = await auth.refreshAccessToken();
auth.detachFrom(apiDio);
```

Proactive failure returns false without expiring session.

## Retry note

Dio request bodies backed by one-shot streams cannot always be replayed. Buffer
upload data when requests must survive token refresh.

See `example/` for runnable Android, iOS, and web Flutter app.

## More documentation

- [API reference](doc/api-reference.md)
- [Package guide](doc/package-guide.md)
- [Session API contract](doc/session-api-contract.md)
- [TimelyFrontEnd integration](doc/timely-frontend-integration.md)
