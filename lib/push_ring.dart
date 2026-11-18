import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'models.dart';

typedef PushHandler = Future<void> Function(CallNotice notice);
typedef TokenHandler = Future<void> Function(String platform, String token);

PushHandler? _onNotice;
CallNotice? _latestIncoming;
final Set<String> _closedRings = {};
final Set<String> _shownRings = {};

void closeRing(String callId) {
  if (callId.isNotEmpty) _closedRings.add(callId);
}

Future<void> dismissRing(String callId) async {
  closeRing(callId);
  if (callId.isEmpty) return;
  await FlutterCallkitIncoming.hideCallkitIncoming(CallKitParams(id: callId));
}

CallNotice _fill(CallNotice notice) {
  final latest = _latestIncoming;
  if (latest == null) return notice;
  final same = notice.callId.isEmpty || notice.callId == latest.callId;
  if (!same && notice.merchantNo.isNotEmpty) return notice;
  return CallNotice(
    event: notice.event,
    callId: notice.callId.isEmpty ? latest.callId : notice.callId,
    merchantNo: notice.merchantNo.isEmpty ? latest.merchantNo : notice.merchantNo,
    hotelId: notice.hotelId.isEmpty ? latest.hotelId : notice.hotelId,
    machineCode: notice.machineCode.isEmpty ? latest.machineCode : notice.machineCode,
    machineName: notice.machineName.isEmpty ? latest.machineName : notice.machineName,
    reason: notice.reason,
  );
}

Future<void> startPush({required PushHandler onNotice, required TokenHandler onToken}) async {
  _onNotice = onNotice;
  FlutterCallkitIncoming.onEvent.listen((event) async {
    if (event == null) return;
    if (event.event == Event.actionDidUpdateDevicePushTokenVoip) {
      final token = '${event.body['deviceTokenVoIP'] ?? event.body ?? ''}'.trim();
      if (token.isNotEmpty) await onToken('ios', token);
      return;
    }
    final body = event.body is Map ? Map<dynamic, dynamic>.from(event.body as Map) : <dynamic, dynamic>{};
    final notice = _fill(CallNotice.fromMap(body));
    if (event.event == Event.actionCallAccept) {
      closeRing(notice.callId);
      await onNotice(CallNotice(
        event: 'accept',
        callId: notice.callId,
        merchantNo: notice.merchantNo,
        hotelId: notice.hotelId,
        machineCode: notice.machineCode,
        machineName: notice.machineName,
      ));
    } else if (event.event == Event.actionCallDecline || event.event == Event.actionCallTimeout) {
      await onNotice(CallNotice(
        event: 'decline',
        callId: notice.callId,
        merchantNo: notice.merchantNo,
        hotelId: notice.hotelId,
        machineCode: notice.machineCode,
        machineName: notice.machineName,
      ));
    } else if (event.event == Event.actionCallIncoming) {
      await onNotice(CallNotice(
        event: 'ring',
        callId: notice.callId,
        merchantNo: notice.merchantNo,
        hotelId: notice.hotelId,
        machineCode: notice.machineCode,
        machineName: notice.machineName,
      ));
    }
  });
  if (Platform.isIOS) {
    final existing = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    final token = '$existing'.trim();
    if (token.isNotEmpty && token != 'null') await onToken('ios', token);
    return;
  }
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundRing);
    FirebaseMessaging.onMessage.listen(_showFromRemote);
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: false, sound: true);
    await FlutterCallkitIncoming.requestNotificationPermission(<String, dynamic>{});
    await FlutterCallkitIncoming.requestFullIntentPermission();
    final token = await messaging.getToken();
    if (token != null && token.isNotEmpty) await onToken('android', token);
    messaging.onTokenRefresh.listen((next) => onToken('android', next));
  } catch (_) {}
}

@pragma('vm:entry-point')
Future<void> firebaseBackgroundRing(RemoteMessage message) async {
  await showIncoming(message.data);
}

Future<void> _showFromRemote(RemoteMessage message) async {
  final notice = CallNotice.fromMap(message.data);
  final here = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  if (here && notice.event == 'incoming') {
    _latestIncoming = notice;
    if (_closedRings.contains(notice.callId)) return;
    if (_onNotice != null) await _onNotice!(notice);
    return;
  }
  await showIncoming(message.data);
}

Future<void> showIncoming(Map<String, dynamic> data) async {
  final notice = CallNotice.fromMap(data);
  if (notice.callId.isEmpty) return;
  if (notice.event == 'incoming') {
    _latestIncoming = notice;
    if (_closedRings.contains(notice.callId) || _shownRings.contains(notice.callId)) return;
    _shownRings.add(notice.callId);
    await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
      id: notice.callId,
      nameCaller: notice.label,
      appName: '櫃台通話',
      handle: notice.machineCode,
      type: 1,
      duration: 30000,
      textAccept: '接聽',
      textDecline: '拒接',
      extra: <String, dynamic>{
        'event': 'incoming',
        'callId': notice.callId,
        'merchantNo': notice.merchantNo,
        'hotelId': notice.hotelId,
        'machineCode': notice.machineCode,
        'machineName': notice.machineName,
      },
      android: const AndroidParams(isCustomNotification: true, isShowFullLockedScreen: true, isImportant: true),
    ));
    return;
  }
  if (notice.event == 'dismiss' || notice.event == 'rejected' || notice.event == 'cancelled') {
    await dismissRing(notice.callId);
    if (_onNotice != null) await _onNotice!(notice);
    return;
  }
  if (_onNotice != null) await _onNotice!(notice);
}
