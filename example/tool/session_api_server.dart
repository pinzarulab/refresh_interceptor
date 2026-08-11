import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final port = int.tryParse(
        Platform.environment['SESSION_API_PORT'] ?? '',
      ) ??
      8080;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  var refreshGeneration = 0;
  var forceSessionExpiry = false;

  stdout.writeln('Session API example: http://127.0.0.1:$port');
  stdout.writeln('POST /login/');
  stdout.writeln('POST /refresh/');
  stdout.writeln('GET  /profile/');

  await for (final request in server) {
    _setHeaders(request.response);
    if (request.method == 'OPTIONS') {
      await request.response.close();
      continue;
    }

    final path = request.uri.path;
    stdout.writeln('${request.method} $path');

    try {
      if (request.method == 'POST' && path == '/login/') {
        final body = await _readJson(request);
        if (body['email'] == null || body['password'] == null) {
          await _respond(request, 422, {'detail': 'Invalid login payload'});
          continue;
        }
        await _respond(request, 200, {
          'access_token': 'expired-access',
          'refresh_token': 'valid-refresh',
        });
        continue;
      }

      if (request.method == 'POST' && path == '/refresh/') {
        final body = await _readJson(request);
        final token = body['refresh_token'];
        final valid = token == 'valid-refresh' ||
            token.toString().startsWith('rotated-refresh-');
        if (forceSessionExpiry || !valid) {
          await _respond(request, 401, {
            'detail': 'Refresh token has expired',
          });
          continue;
        }

        await Future<void>.delayed(const Duration(milliseconds: 300));
        refreshGeneration++;
        await _respond(request, 200, {
          'access_token': 'fresh-access-$refreshGeneration',
          'refresh_token': 'rotated-refresh-$refreshGeneration',
        });
        continue;
      }

      if (request.method == 'GET' && path == '/profile/') {
        final authorization =
            request.headers.value(HttpHeaders.authorizationHeader);
        final valid = authorization?.startsWith('Bearer fresh-access-') == true;
        if (forceSessionExpiry || !valid) {
          await _respond(request, 401, {'detail': 'Token has expired'});
          continue;
        }

        await _respond(request, 200, {
          'id': 'example-user',
          'fullName': 'Example User',
          'email': 'user@example.com',
          'groupId': 'example-group',
          'groupName': 'Example Group',
          'message': 'Protected profile request succeeded',
        });
        continue;
      }

      if (request.method == 'POST' && path == '/test/expire-session') {
        forceSessionExpiry = true;
        await _respond(request, 200, {'force_session_expiry': true});
        continue;
      }

      if (request.method == 'POST' && path == '/test/reset') {
        refreshGeneration = 0;
        forceSessionExpiry = false;
        await _respond(request, 200, {'reset': true});
        continue;
      }

      await _respond(request, 404, {'detail': 'Not Found'});
    } on FormatException catch (error) {
      await _respond(request, 400, {'detail': error.message});
    } catch (error, stackTrace) {
      stderr.writeln('$error\n$stackTrace');
      await _respond(request, 500, {'detail': 'Internal Server Error'});
    }
  }
}

void _setHeaders(HttpResponse response) {
  response.headers
    ..contentType = ContentType.json
    ..set('Access-Control-Allow-Origin', '*')
    ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type')
    ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
}

Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
  final text = await utf8.decoder.bind(request).join();
  if (text.isEmpty) return <String, dynamic>{};
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object');
  }
  return decoded;
}

Future<void> _respond(
  HttpRequest request,
  int statusCode,
  Object body,
) async {
  request.response
    ..statusCode = statusCode
    ..write(jsonEncode(body));
  await request.response.close();
}
