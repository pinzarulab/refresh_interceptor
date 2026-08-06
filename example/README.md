# Flutter example

Run from this directory:

```sh
flutter pub get
flutter run
```

Press **Run concurrent requests**. Three 401 responses produce one refresh call,
then all three original requests retry successfully with the new access token.

