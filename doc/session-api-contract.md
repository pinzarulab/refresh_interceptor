# Session API contract

This document defines the HTTP behavior expected by TimelyFrontEnd and
`refresh_interceptor`. It is derived from the current Retrofit services and
token DTOs. The Session API source repository is referenced at
<https://github.com/PinzaruDaniel/session_api>; repository-specific installation
commands should be added after the server source is available locally.

## Base URL

Timely reads the base URL from `API_BASE_URL`:

```sh
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

## Token model

Successful login and refresh responses use snake_case JSON keys:

```json
{
  "access_token": "access-token-value",
  "refresh_token": "refresh-token-value"
}
```

The refresh token may be omitted when rotation is disabled. The access token
must be non-empty.

## Endpoints

### POST `/login/`

Request:

```json
{
  "email": "user@example.com",
  "password": "password123"
}
```

Success: HTTP 200 with access and refresh tokens.

Invalid credentials should return HTTP 401. Login and refresh are public and
must not require an existing access token.

### POST `/refresh/`

Request:

```json
{
  "refresh_token": "refresh-token-value"
}
```

Success: HTTP 200 with a new access token and optional rotated refresh token.

An expired, revoked, malformed, or unknown refresh token must return HTTP 401
or 403. That response is the permanent-session-expiry signal consumed by the
interceptor.

### GET `/profile/`

Request header:

```text
Authorization: Bearer <access_token>
```

Success: HTTP 200. Timely accepts these profile fields:

```json
{
  "id": "user-id",
  "fullName": "Example User",
  "email": "user@example.com",
  "groupId": "group-id",
  "groupName": "Example Group",
  "message": "optional message"
}
```

Expired access tokens return HTTP 401. Current server responses may use:

```json
{
  "detail": "Token has expired"
}
```

The client detects expiry by status code; this message is informational.

## Status-code semantics

| Status | Client behavior |
| --- | --- |
| 200 | Parse response and continue. |
| 400/422 | Treat request payload as invalid; do not log out automatically. |
| 401/403 from protected endpoint | Attempt one shared token refresh. |
| 401/403 from refresh endpoint | Clear tokens and show session-expired UI once. |
| 404 | Endpoint/resource missing; do not log out. |
| 500–599 | Transient server failure; preserve stored session. |

## Curl verification

Login:

```sh
curl -i -X POST http://127.0.0.1:8000/login/ \
  -H 'content-type: application/json' \
  -d '{"email":"user@example.com","password":"password123"}'
```

Profile:

```sh
curl -i http://127.0.0.1:8000/profile/ \
  -H 'Authorization: Bearer ACCESS_TOKEN'
```

Refresh:

```sh
curl -i -X POST http://127.0.0.1:8000/refresh/ \
  -H 'content-type: application/json' \
  -d '{"refresh_token":"REFRESH_TOKEN"}'
```

## Compatibility checklist

- Login and refresh response keys remain `access_token` and `refresh_token`.
- Refresh endpoint does not require a valid access token.
- Protected endpoints use `Authorization: Bearer`.
- Expired access token produces 401/403, not 404 or 500.
- Invalid refresh token produces 401/403.
- Refresh rotation is atomic: old token becomes invalid only when new tokens
  are returned successfully.
- Concurrent protected failures can reuse one refresh result.
