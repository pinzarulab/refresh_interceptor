# Flutter example with local Session API

This example sends real HTTP requests through Dio. A separate Dart server
implements the Session API contract used by Timely:

- `POST /login/`
- `POST /refresh/`
- `GET /profile/`

It also exposes `/test/reset` and `/test/expire-session` for deterministic demo
scenarios.

## 1. Start the Dart server

From `example`:

```sh
dart run tool/session_api_server.dart
```

Default address is `http://127.0.0.1:8080`. Override port:

```sh
SESSION_API_PORT=9090 dart run tool/session_api_server.dart
```

## 2. Run Flutter app

iOS Simulator, macOS, or web:

```sh
flutter run \
  --dart-define=SESSION_API_URL=http://127.0.0.1:8080
```

Android emulator:

```sh
flutter run \
  --dart-define=SESSION_API_URL=http://10.0.2.2:8080
```

Physical device:

```sh
flutter run \
  --dart-define=SESSION_API_URL=http://YOUR_MAC_LAN_IP:8080
```

Server binds to `0.0.0.0`, so a phone on the same network can reach it. Allow
local-network/firewall prompts when asked.

## Scenarios

### Run successful refresh

1. Test state resets.
2. Login returns `expired-access` and `valid-refresh`.
3. Three concurrent `/profile/` calls return 401.
4. All failures share one `/refresh/` request.
5. Rotated tokens are stored.
6. All three profile calls retry and succeed.

Expected event log includes `Refresh HTTP calls: 1`.

### Run permanent expiry

1. Login stores an expired access token and valid refresh token.
2. Test endpoint configures server to reject both tokens.
3. `/profile/` returns 401.
4. `/refresh/` returns 401 with `Refresh token has expired`.
5. Package clears tokens and presents configured session-expired widget once.

## Manual API calls

```sh
curl -i -X POST http://127.0.0.1:8080/login/ \
  -H 'content-type: application/json' \
  -d '{"email":"user@example.com","password":"password123"}'

curl -i http://127.0.0.1:8080/profile/ \
  -H 'Authorization: Bearer expired-access'

curl -i -X POST http://127.0.0.1:8080/refresh/ \
  -H 'content-type: application/json' \
  -d '{"refresh_token":"valid-refresh"}'
```

## Verify

```sh
flutter analyze
flutter test
```
