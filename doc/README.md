# Documentation

- [API reference](api-reference.md) — public classes, callbacks, methods,
  options, and lifecycle semantics.
- [Package guide](package-guide.md) — install, initialize, configure, and test
  `refresh_interceptor`.
- [Session API contract](session-api-contract.md) — HTTP contract required by
  token refresh clients.
- [TimelyFrontEnd integration](timely-frontend-integration.md) — concrete
  Injectable, ObjectBox, Dio, and Flutter setup used by Timely.

Start with the package guide when adding the interceptor to another app. Use
the integration guide when changing Timely. Backend developers should treat
the Session API contract as the compatibility checklist.
