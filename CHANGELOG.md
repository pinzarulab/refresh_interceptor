## 0.2.2

- Stopped missing-token request rejection from emitting session expiry by
  default; added `expireSessionOnMissingToken` for opt-in legacy behavior.

## 0.2.1

- Treated refresh-endpoint authentication rejections as permanent session
  expiry instead of transient refresh failures.
- Added regression coverage for a refresh request returning 401.
- Added singleton `RefreshInit` for initializing an app-provided
  session-expired widget before dependency injection.

## 0.2.0

- Kept tokens and session state intact when refresh fails because of a
  transient exception, such as a network or storage error.
- Prevented stale refresh operations from overwriting a reset login session.
- Prevented excluded requests from triggering refresh or session expiry.
- Guarded predicates and error callbacks so callback failures cannot strand
  Dio interceptor handlers.
- Protected newer stored tokens from session expiry caused by an older retry.
- Added regression coverage for refresh failures, public routes, session
  replacement, and callback errors.

## 0.1.0

- Initial release with token injection, single-flight refresh, request retry,
  refresh-token rotation, and session-expiry handling.
- Simplified setup with `RefreshInterceptor.attachTo` and `attachToAll`.
- Added shared refresh state across multiple Dio clients.
- Added `TokenStoreAdapter` for existing storage method tear-offs.
- Added automatic new-session detection and safe duplicate attachment.
- Preserved non-auth errors returned by retried requests.
