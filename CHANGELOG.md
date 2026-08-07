## 0.1.0

- Initial release with token injection, single-flight refresh, request retry,
  refresh-token rotation, and session-expiry handling.
- Simplified setup with `RefreshInterceptor.attachTo` and `attachToAll`.
- Added shared refresh state across multiple Dio clients.
- Added `TokenStoreAdapter` for existing storage method tear-offs.
- Added automatic new-session detection and safe duplicate attachment.
- Preserved non-auth errors returned by retried requests.
