# API reference

Public API for `refresh_interceptor` 0.4.0.

## Import

```dart
import 'package:refresh_interceptor/refresh_interceptor.dart';
```

## RefreshInterceptor

`RefreshInterceptor` manages access-token attachment, single-flight refresh,
request retry, and session-expiry notification for one authenticated session.
Create one instance and attach it to every Dio client sharing those tokens.

```dart
final interceptor = RefreshInterceptor(
  readAccessToken: authStorage.getAccessToken,
  readRefreshToken: authStorage.getRefreshToken,
  saveTokens: authStorage.updateTokens,
  clearTokens: authStorage.clearTokens,
  onRefresh: refreshTokens,
);

interceptor.attachToAll([profileDio, scheduleDio]);
```

Use a separate, unattached Dio client inside `onRefresh`. Attaching the refresh
client can recursively intercept a rejected refresh request.

### Required callbacks

| Parameter | Signature | Responsibility |
| --- | --- | --- |
| `readAccessToken` | `FutureOr<String?> Function()` | Return current access token. |
| `readRefreshToken` | `FutureOr<String?> Function()` | Return current refresh token. |
| `saveTokens` | `FutureOr<void> Function(String, String?)` | Persist refreshed tokens before retry. Null refresh token means keep existing value. |
| `clearTokens` | `FutureOr<void> Function()` | Remove stored auth tokens after permanent expiry. |
| `onRefresh` | `Future<RefreshTokens?> Function(String)` | Exchange current refresh token for new tokens. |

### Optional configuration

| Parameter | Default | Behavior |
| --- | --- | --- |
| `onSessionExpired` | `RefreshInit.instance.showSessionExpired` | Handles permanent session expiry. |
| `shouldRefresh` | HTTP 401 | Selects errors requiring authentication recovery. |
| `shouldAttachToken` | All requests | Selects requests receiving auth handling. |
| `authorizationHeader` | `Authorization` | Header containing access token. |
| `tokenPrefix` | `Bearer` | Scheme before token. Empty string sends raw token. |
| `rejectIfTokenMissing` | `false` | Rejects locally instead of sending request without token. |
| `expireSessionOnMissingToken` | `false` | Shows session expiry after missing-token rejection. Requires `rejectIfTokenMissing`. |
| `clearTokensOnRefreshFailure` | `true` | Clears tokens after permanent refresh rejection. |
| `onError` | null | Observes transient refresh, storage, predicate, and callback errors. |

### attachTo

```dart
interceptor.attachTo(apiDio);
```

Adds one bound Dio interceptor. Repeated calls with the same Dio instance are
safe and do not add duplicates.

### attachToAll

```dart
interceptor.attachToAll([profileDio, scheduleDio, notificationDio]);
```

Attaches all clients to the same refresh manager. Concurrent authentication
failures across those clients share one refresh request.

### detachFrom

```dart
interceptor.detachFrom(apiDio);
```

Removes only this package's bound interceptor. Other Dio interceptors remain.

### refreshAccessToken

```dart
final refreshed = await interceptor.refreshAccessToken();
```

Starts proactive refresh or joins one already running. Returns true only after
new tokens are stored. Failure returns false and does not expire session.

### resetSession

```dart
interceptor.resetSession();
await authStorage.updateTokens(accessToken, refreshToken);
```

Call before login, logout, account switch, or manual token replacement. It
invalidates refresh work started by the previous session and resets expiry
deduplication. Observing a different access token also resets state.

## RefreshTokens

Successful `onRefresh` result:

```dart
return RefreshTokens(
  accessToken: response.accessToken,
  refreshToken: response.refreshToken,
);
```

`accessToken` must be non-empty. `refreshToken` may be null when server does not
rotate it; `saveTokens` must then preserve current stored refresh token.

Return null from `onRefresh` only for permanent refresh rejection. Throw
transient failures such as connection errors, timeouts, and server errors.

## RefreshInit

Optional Flutter presenter for session-expired UI.

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await RefreshInit.instance.initialize(
    sessionExpiredWidget: const SessionExpiredDialog(),
    barrierDismissible: false,
  );

  await initDI(get: getIt.instance);
  runApp(const App());
}
```

Connect its key to the root app:

```dart
MaterialApp(
  navigatorKey: RefreshInit.instance.navigatorKey,
  home: const HomePage(),
);
```

### instance

Singleton presenter used when `RefreshInterceptor.onSessionExpired` is omitted.

### navigatorKey

Root navigator key used to show the configured widget without requiring a
screen context.

### isInitialized

True after `initialize` receives a session-expired widget.

### initialize

Configures widget and modal barrier. Reinitialization replaces previous
configuration and resets presentation state.

### showSessionExpired

Shows one dialog for concurrent calls. Returns immediately without waiting for
dialog closure. If navigator is not ready, presentation is scheduled for next
frame. Throws `StateError` when `initialize` was not called.

## Failure semantics

| Event | Result |
| --- | --- |
| Protected request returns matching auth error | Start or join refresh. |
| Refresh succeeds | Save tokens, retry original request once. |
| Refresh returns null or matching `DioException` | Permanent expiry; optionally clear tokens and notify once. |
| Refresh throws timeout, connection error, or non-matching error | Report through `onError`; preserve tokens and original request error. |
| Retried request fails authentication again | Expire session; never refresh twice. |
| Session changes during refresh | Discard stale refresh result. |

## Callback contracts

Storage callbacks may be synchronous or asynchronous. Async writes must finish
before their returned future completes. Exceptions are reported through
`onError`; interceptor avoids leaving Dio handlers unresolved.

Predicate callbacks should be fast and side-effect free. A thrown predicate
error is reported through `onError` and treated as false.
