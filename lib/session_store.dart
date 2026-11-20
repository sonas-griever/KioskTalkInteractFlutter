import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'config.dart';
import 'models.dart';

const _native = MethodChannel('kiosk_talk/session');

const _key = 'kiosk-talk-session';
const _seen = 'kiosk-talk-seen-history';
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

Future<void> writeSession(StaffSession session) async {
  await _storage.write(key: _key, value: jsonEncode(session.toJson()));
  await publishNativeSession(session);
}

Future<void> clearSession() async {
  await _storage.delete(key: _key);
  await publishNativeSession(null);
}

Future<void> publishNativeSession(StaffSession? session) async {
  try {
    if (session == null || session.token.isEmpty) {
      await _native.invokeMethod('clear');
      return;
    }
    await _native.invokeMethod('save', {'token': session.token, 'api': apiBase});
  } catch (_) {}
}

Future<int> readSeenAt() async {
  final raw = await _storage.read(key: _seen);
  return int.tryParse(raw ?? '') ?? 0;
}

Future<void> writeSeenAt(int value) {
  return _storage.write(key: _seen, value: '$value');
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
