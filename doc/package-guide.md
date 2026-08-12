# refresh_interceptor package guide

## Purpose

`refresh_interceptor` adds stored access tokens to Dio requests, performs one
shared refresh when protected requests fail, persists rotated tokens, retries
the original request once, and reports permanent session expiry.

Use one `RefreshInterceptor` instance for one authenticated user session.
Attach that instance to every protected Dio client that shares the same token
storage.

## Install

Published package:

```yaml
dependencies:
  refresh_interceptor: ^0.4.0
```

Local development:

```yaml
dependencies:
  refresh_interceptor:
    path: ../refresh_interceptor
```

The package accepts a Flutter `Widget` for session-expired UI, so consuming
projects must use Flutter.

## Initialize Flutter UI

Initialize before dependency injection creates any interceptor:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await RefreshInit.instance.initialize(
    sessionExpiredWidget: const SessionExpiredDialog(),
  );

  await initDI(get: GetIt.instance);
  runApp(const MyApp());
}
```

Connect the package navigator key once:

```dart
MaterialApp(
  navigatorKey: RefreshInit.instance.navigatorKey,
  home: const HomePage(),
)
```

`GetMaterialApp` works the same way. `RefreshInit` prevents duplicate dialogs
and does not keep Dio waiting while the user interacts with the widget.

## Configure networking

Use a separate Dio client for login and refresh. Never attach the refresh
interceptor to the client used by `onRefresh`, or a rejected refresh request
could intercept itself.

```dart
final authDio = Dio(BaseOptions(baseUrl: apiBaseUrl));
final appDio = Dio(BaseOptions(baseUrl: apiBaseUrl));

final refreshInterceptor = RefreshInterceptor(
  readAccessToken: tokenStorage.getAccessToken,
  readRefreshToken: tokenStorage.getRefreshToken,
  saveTokens: (accessToken, refreshToken) => tokenStorage.saveTokens(
    accessToken: accessToken,
    refreshToken: refreshToken,
  ),
  clearTokens: tokenStorage.clearTokens,
  onRefresh: (refreshToken) async {
    final response = await authDio.post<Map<String, dynamic>>(
      '/refresh/',
      data: {'refresh_token': refreshToken},
    );
    final data = response.data!;
    return RefreshTokens(
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String?,
    );
  },
  shouldRefresh: (error) {
    final status = error.response?.statusCode;
    return status == 401 || status == 403;
  },
  rejectIfTokenMissing: true,
);

refreshInterceptor.attachToAll([appDio]);
```

When `onSessionExpired` is omitted, `RefreshInterceptor` uses the widget
registered by `RefreshInit`. Pass an explicit callback when navigation or state
management must be handled outside the package.

## Runtime behavior

| Situation | Result |
| --- | --- |
| Access token exists and request succeeds | Response passes through. |
| Several requests return 401 together | One refresh runs; all callers share it. |
| Refresh succeeds | Tokens are saved before requests retry once. |
| Server rotates refresh token | New refresh token is stored. |
| Response omits rotated refresh token | Existing refresh token is preserved. |
| Refresh returns 401/403 matching `shouldRefresh` | Tokens are cleared and expiry UI is shown once. |
| Refresh throws timeout, connection error, or 5xx | Session remains stored; error is reported through `onError`. |
| Retried request returns another auth failure | No second refresh; session expires. |
| No access token exists | Request can be rejected without showing expiry UI. |

## Missing-token behavior

Missing tokens normally mean the user is already logged out:

```dart
RefreshInterceptor(
  // ...
  rejectIfTokenMissing: true,
  expireSessionOnMissingToken: false,
)
```

Set `expireSessionOnMissingToken: true` only if missing storage during an active
screen must show session-expired UI. Applications should avoid protected API
calls during anonymous startup whenever possible.

## Session lifecycle

Call `resetSession()` before manually replacing tokens during login, logout,
or account switching:

```dart
refreshInterceptor.resetSession();
await tokenStorage.saveTokens(
  accessToken: accessToken,
  refreshToken: refreshToken,
);
```

This prevents an older in-flight refresh from overwriting a newer login. A
different stored access token is also detected automatically on a later
request.

## Configuration reference

| Option | Default | Meaning |
| --- | --- | --- |
| `authorizationHeader` | `Authorization` | Header receiving the access token. |
| `tokenPrefix` | `Bearer` | Authentication scheme; use an empty string for raw tokens. |
| `shouldRefresh` | HTTP 401 | Determines authentication failures. |
| `shouldAttachToken` | every request | Excludes public routes or separate APIs. |
| `rejectIfTokenMissing` | `false` | Reject before network when access token is absent. |
| `expireSessionOnMissingToken` | `false` | Shows expiry UI for missing-token rejection. |
| `clearTokensOnRefreshFailure` | `true` | Clears storage after permanent refresh rejection. |
| `onError` | `null` | Observes transient refresh/storage/callback failures. |

## Verification

```sh
flutter test
flutter analyze
cd example
flutter analyze
```

The example app includes a button that presents the configured session-expired
widget and a concurrent-request refresh demonstration.

## Common mistakes

- Attaching the interceptor to refresh Dio.
- Starting profile requests before checking whether an access token exists.
- Forgetting to await token storage writes before retry.
- Creating one interceptor per Dio client, which defeats cross-client
  single-flight refresh.
- Treating ordinary 404 or 500 responses as session expiry.
- Forgetting `RefreshInit.instance.navigatorKey` on the root app navigator.
