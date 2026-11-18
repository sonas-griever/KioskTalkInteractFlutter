import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

const _key = 'kiosk-talk-session';
const _storage = FlutterSecureStorage();

Future<StaffSession?> readSession() async {
  final raw = await _storage.read(key: _key);
  if (raw == null || raw.isEmpty) return null;
  try {
    final session = StaffSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    if (session.token.isEmpty || session.account.isEmpty || _expired(session.token)) {
      await _storage.delete(key: _key);
      return null;
    }
    return session;
  } catch (_) {
    await _storage.delete(key: _key);
    return null;
  }
}

Future<void> writeSession(StaffSession session) {
  return _storage.write(key: _key, value: jsonEncode(session.toJson()));
}

Future<void> clearSession() {
  return _storage.delete(key: _key);
}

bool _expired(String token) {
  final body = token.split('.').firstOrNull;
  if (body == null || body.isEmpty) return true;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(body)))) as Map<String, dynamic>;
    final exp = payload['exp'];
    final seconds = exp is int ? exp : int.tryParse('$exp') ?? 0;
    return seconds * 1000 <= DateTime.now().millisecondsSinceEpoch;
  } catch (_) {
    return true;
  }
}
