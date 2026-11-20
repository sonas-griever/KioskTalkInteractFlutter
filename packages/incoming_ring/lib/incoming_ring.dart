import 'package:flutter/services.dart';

class IncomingRing {
  static const _channel = MethodChannel('kiosk_talk/incoming_ring');

  static Future<void> start({bool tone = false}) async {
    try {
      await _channel.invokeMethod<void>('start', {'tone': tone});
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
