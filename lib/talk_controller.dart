import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'api.dart';
import 'kvs_viewer.dart';
import 'models.dart';
import 'push_ring.dart';
import 'session_store.dart';

enum CallPhase { idle, dialing, incoming, connecting, inCall, ended }

class TalkController extends ChangeNotifier {
  final api = TalkApi(null);
  StaffSession? session;
  CallPhase phase = CallPhase.idle;
  String message = '';
  String merchantNo = '';
  String callId = '';
  String hotelId = '';
  String machineCode = '';
  String machineName = '';
  bool muted = false;
  bool remoteControl = false;
  bool screenLarge = true;
  bool showSmall = true;
  final media = KvsViewer();
  String? _deviceToken;
  String? _platform;
  Timer? _wait;
  var _closedMerchant = '';
  final Set<String> _taken = {};

  String get peerLabel => machineName.isEmpty ? machineCode : '$machineName（$machineCode）';

  Future<void> restore() async {
    session = await readSession();
    api.session = session;
    notifyListeners();
  }

  Future<void> login(String account, String password) async {
    session = await api.login(account, password);
    await writeSession(session!);
    notifyListeners();
    await _registerCurrentDevice();
  }

  void clearLocalSession() {
    session = null;
    api.session = null;
    notifyListeners();
  }

  Future<void> logout() async {
    final token = _deviceToken;
    if (token != null) {
      try {
        await api.removeDevice(token);
      } catch (_) {}
    }
    await clearSession();
    session = null;
    api.session = null;
    await _reset(CallPhase.idle, '');
  }

  Future<void> onDeviceToken(String platform, String token) async {
    _platform = platform;
    _deviceToken = token;
    api.deviceToken = token;
    await _registerCurrentDevice();
  }

  Future<void> onNotice(CallNotice notice) async {
    if (notice.merchantNo.isNotEmpty && notice.merchantNo == _closedMerchant && notice.event != 'incoming') return;
    if (notice.event == 'ring') {
      if (_taken.contains(notice.callId) || phase == CallPhase.inCall || phase == CallPhase.connecting) {
        await dismissRing(notice.callId);
        return;
      }
      _remember(notice);
      return;
    }
    if (notice.event == 'incoming') {
      if (_taken.contains(notice.callId) || phase == CallPhase.inCall || phase == CallPhase.connecting) {
        await dismissRing(notice.callId);
        return;
      }
      _remember(notice);
      phase = CallPhase.incoming;
      message = '';
      notifyListeners();
      return;
    }
    if (notice.event == 'accept') {
      _remember(notice);
      await accept();
      return;
    }
    if (notice.event == 'decline') {
      if (_taken.contains(notice.callId) || phase == CallPhase.connecting || phase == CallPhase.inCall) {
        await dismissRing(notice.callId.isEmpty ? callId : notice.callId);
        return;
      }
      _remember(notice);
      await decline();
      return;
    }
    if (notice.event == 'dismiss' || notice.event == 'cancelled') {
      final id = notice.callId.isEmpty ? callId : notice.callId;
      await dismissRing(id);
      final same = notice.merchantNo.isEmpty || merchantNo.isEmpty || notice.merchantNo == merchantNo || (notice.callId.isNotEmpty && notice.callId == callId);
      if (!same || phase == CallPhase.idle) return;
      if (notice.reason == 'answered' && phase != CallPhase.incoming) return;
      if (phase == CallPhase.incoming) {
        await _reset(CallPhase.idle, notice.reason == 'answered' ? '這通已由其他人接聽' : '對方已取消');
        return;
      }
      await _reset(CallPhase.ended, '通話已結束');
      return;
    }
    if (notice.merchantNo != merchantNo && merchantNo.isNotEmpty) return;
    if (notice.event == 'answered' && phase == CallPhase.dialing) {
      await _connect(notice.merchantNo);
      return;
    }
    if (notice.event == 'rejected') {
      await _reset(CallPhase.ended, '對方拒接');
    }
  }

  Future<void> catchUp() async {
    if (phase != CallPhase.incoming || session == null || merchantNo.isEmpty) return;
    try {
      final rows = await api.calls();
      CallLog? row;
      for (final item in rows) {
        if (item.merchantNo == merchantNo) {
          row = item;
          break;
        }
      }
      if (row == null || row.status == 'ringing') return;
      await dismissRing(callId);
      await _reset(CallPhase.idle, row.status == 'answered' ? '這通已由其他人接聽' : '對方已取消');
    } catch (_) {}
  }

  Future<void> callMachine(Hotel hotel, Machine machine) async {
    if (phase != CallPhase.idle && phase != CallPhase.ended) return;
    hotelId = hotel.id;
    machineCode = machine.code;
    machineName = machine.name;
    phase = CallPhase.dialing;
    message = '';
    notifyListeners();
    try {
      final notice = await api.startCall(hotel.id, machine.code);
      _remember(notice);
      _wait?.cancel();
      _wait = Timer(const Duration(seconds: 35), () {
        if (phase == CallPhase.dialing && merchantNo == notice.merchantNo) {
          unawaited(hangup(message: '對方沒有接聽'));
        }
      });
    } on ApiException catch (error) {
      await _fail(error);
    }
  }

  Future<void> accept() async {
    if (phase == CallPhase.connecting || phase == CallPhase.inCall) {
      await dismissRing(callId);
      return;
    }
    if (merchantNo.isEmpty) return;
    final id = callId;
    _taken.add(id);
    phase = CallPhase.connecting;
    message = '';
    notifyListeners();
    await dismissRing(id);
    unawaited(_dismissLateRing(id));
    try {
      final result = await api.answer(merchantNo);
      _remember(result.notice);
      await _open(result.viewer);
    } on ApiException catch (error) {
      if (id.isNotEmpty) await FlutterCallkitIncoming.endCall(id);
      await _fail(error);
    }
  }

  Future<void> _dismissLateRing(String id) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await dismissRing(id);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await dismissRing(id);
  }

  Future<void> decline() async {
    final current = merchantNo;
    if (current.isEmpty) return;
    _closedMerchant = current;
    try {
      await api.reject(current);
    } catch (_) {}
    if (callId.isNotEmpty) await FlutterCallkitIncoming.endCall(callId);
    await _reset(CallPhase.idle, '');
  }

  Future<void> hangup({String message = ''}) async {
    final current = merchantNo;
    _closedMerchant = current;
    _wait?.cancel();
    if (current.isNotEmpty) {
      try {
        await api.hangup(current);
      } catch (_) {}
    }
    if (callId.isNotEmpty) await FlutterCallkitIncoming.endCall(callId);
    await media.close();
    await _reset(CallPhase.ended, message);
  }

  void toggleMute() {
    muted = !muted;
    media.setMuted(muted);
    notifyListeners();
  }

  void toggleRemote() {
    remoteControl = !remoteControl;
    notifyListeners();
  }

  void swapVideo() {
    screenLarge = !screenLarge;
    notifyListeners();
  }

  void toggleSmall() {
    showSmall = !showSmall;
    notifyListeners();
  }

  void tapVideo(double x, double y) {
    if (!remoteControl || phase != CallPhase.inCall) return;
    media.sendClick(x, y);
  }

  Future<void> _connect(String number) async {
    phase = CallPhase.connecting;
    notifyListeners();
    try {
      final result = await api.sessionFor(number);
      _remember(result.notice);
      await _open(result.viewer);
    } on ApiException catch (error) {
      await _fail(error);
    }
  }

  Future<void> _open(ViewerTicket ticket) async {
    await media.connect(ticket, notifyListeners);
    if (callId.isNotEmpty) await FlutterCallkitIncoming.setCallConnected(callId);
    phase = CallPhase.inCall;
    muted = false;
    remoteControl = false;
    notifyListeners();
  }

  void _remember(CallNotice notice) {
    if (notice.merchantNo.isNotEmpty) merchantNo = notice.merchantNo;
    if (notice.callId.isNotEmpty) callId = notice.callId;
    if (notice.hotelId.isNotEmpty) hotelId = notice.hotelId;
    if (notice.machineCode.isNotEmpty) machineCode = notice.machineCode;
    if (notice.machineName.isNotEmpty) machineName = notice.machineName;
  }

  Future<void> _registerCurrentDevice() async {
    final token = _deviceToken;
    final platform = _platform;
    if (session == null || token == null || platform == null) return;
    try {
      await api.registerDevice(platform: platform, token: token);
    } catch (_) {}
  }

  Future<void> _fail(ApiException error) async {
    if (error.status == 401) {
      await clearSession();
      session = null;
      api.session = null;
    }
    await media.close();
    await _reset(CallPhase.ended, error.message);
  }

  Future<void> _reset(CallPhase next, String text) async {
    _wait?.cancel();
    phase = next;
    message = text;
    if (next == CallPhase.idle || next == CallPhase.ended) {
      merchantNo = '';
      callId = '';
      muted = false;
      remoteControl = false;
      screenLarge = true;
      showSmall = true;
    }
    notifyListeners();
  }
}
