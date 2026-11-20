import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:incoming_ring/incoming_ring.dart';

import 'api.dart';
import 'kvs_viewer.dart';
import 'models.dart';
import 'push_ring.dart';
import 'session_store.dart';

enum CallPhase { idle, dialing, incoming, connecting, inCall, ended }

class WaitingCall {
  const WaitingCall({required this.merchantNo, required this.callId, required this.hotelId, required this.machineCode, required this.machineName});

  final String merchantNo;
  final String callId;
  final String hotelId;
  final String machineCode;
  final String machineName;

  String get label => machineName.isEmpty ? machineCode : '$machineName（$machineCode）';
}

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
  final List<WaitingCall> waiting = [];
  int unseenMissed = 0;
  var _seenAt = 0;
  bool muted = false;
  bool speaker = false;
  bool remoteControl = false;
  bool screenLarge = true;
  bool showSmall = true;
  bool fullscreen = false;
  bool? _heldLandscape;
  var _chromeHidden = false;
  var _frameToken = 0;
  final media = KvsViewer();
  String? _deviceToken;
  String? _platform;
  var _pushRegistered = false;
  var _previewing = false;
  static const _lock = MethodChannel('kiosk_talk/lock');
  Timer? _wait;
  Timer? _presence;
  Timer? _credential;
  var _closedMerchant = '';
  final Set<String> _taken = {};

  String get peerLabel => machineName.isEmpty ? machineCode : '$machineName（$machineCode）';
  bool get previewing => _previewing;

  String hotelName(String id) {
    for (final hotel in session?.hotels ?? const <Hotel>[]) {
      if (hotel.id == id && hotel.name.isNotEmpty) return hotel.name;
    }
    return '';
  }
  bool get hasWaiting => waiting.isNotEmpty;
  bool get _busy => phase == CallPhase.dialing || phase == CallPhase.connecting || phase == CallPhase.inCall;

  Future<void> restore() async {
    session = await readSession();
    api.session = session;
    notifyListeners();
    if (session != null) {
      await publishNativeSession(session);
      _seenAt = await readSeenAt();
      _armPresence();
      unawaited(keepAlive());
      unawaited(refreshMissed());
    }
  }

  Future<void> login(String account, String password) async {
    session = await api.login(account, password);
    await writeSession(session!);
    notifyListeners();
    _armPresence();
    await _registerCurrentDevice();
  }

  void clearLocalSession() {
    session = null;
    api.session = null;
    notifyListeners();
  }

  Future<void> logout() async {
    final pending = List<WaitingCall>.of(waiting);
    _clearWaiting();
    for (final item in pending) {
      if (item.merchantNo.isEmpty) continue;
      try {
        await api.reject(item.merchantNo);
      } catch (_) {}
    }
    final current = merchantNo;
    _wait?.cancel();
    if (current.isNotEmpty && phase == CallPhase.incoming) {
      try {
        await api.reject(current);
      } catch (_) {}
    } else if (current.isNotEmpty && _busy) {
      try {
        await api.hangup(current);
      } catch (_) {}
    }
    await media.close();
    final token = _deviceToken;
    if (token != null) {
      try {
        await api.removeDevice(token);
      } catch (_) {}
    }
    _presence?.cancel();
    _pushRegistered = false;
    await clearSession();
    session = null;
    api.session = null;
    await _reset(CallPhase.idle, '');
  }

  Future<void> keepAlive() async {
    final current = session;
    if (current == null) return;
    try {
      final next = await api.refresh(current);
      session = next;
      api.session = next;
      await writeSession(next);
    } on ApiException catch (error) {
      if (error.status == 401) {
        await clearSession();
        session = null;
        api.session = null;
        notifyListeners();
        return;
      }
    } catch (_) {}
    await _registerCurrentDevice();
  }

  Future<void> onDeviceToken(String platform, String token) async {
    _platform = platform;
    _deviceToken = token;
    api.deviceToken = token;
    await _registerCurrentDevice();
  }

  Future<void> onNotice(CallNotice notice) async {
    if (notice.merchantNo.isNotEmpty && notice.merchantNo == _closedMerchant && notice.event != 'incoming') return;
    if (notice.event == 'ring' || notice.event == 'incoming') {
      if (_taken.contains(notice.callId)) {
        await dismissRing(notice.callId);
        return;
      }
      if (_busy && notice.merchantNo != merchantNo) {
        _hold(notice);
        await IncomingRing.stop();
        notifyListeners();
        return;
      }
      if (phase == CallPhase.incoming && notice.merchantNo.isNotEmpty && notice.merchantNo != merchantNo) {
        _hold(notice);
        notifyListeners();
        return;
      }
      if (notice.event == 'ring') {
        _remember(notice);
        return;
      }
      _remember(notice);
      phase = CallPhase.incoming;
      message = '';
      _previewing = false;
      notifyListeners();
      await IncomingRing.start(tone: true);
      return;
    }
    if (notice.event == 'accept') {
      if (_busy && notice.merchantNo != merchantNo) {
        _hold(notice);
        await dismissRing(notice.callId);
        return;
      }
      _remember(notice);
      await accept();
      return;
    }
    if (notice.event == 'decline') {
      await IncomingRing.stop();
      if (notice.merchantNo.isNotEmpty && notice.merchantNo != merchantNo && (_busy || phase == CallPhase.incoming)) {
        _hold(notice);
        WaitingCall? item;
        for (final call in waiting) {
          if (call.merchantNo == notice.merchantNo) item = call;
        }
        if (item != null) await rejectWaiting(item);
        return;
      }
      if (_taken.contains(notice.callId) || _busy) {
        await dismissRing(notice.callId.isEmpty ? callId : notice.callId);
        return;
      }
      _remember(notice);
      if (merchantNo.isEmpty) {
        await dismissRing(notice.callId);
        return;
      }
      await decline();
      return;
    }
    if (notice.event == 'dismiss' || notice.event == 'cancelled') {
      if (_matchesWaiting(notice)) {
        notifyListeners();
        return;
      }
      final id = notice.callId.isEmpty ? callId : notice.callId;
      await dismissRing(id);
      final same = notice.merchantNo.isEmpty || merchantNo.isEmpty || notice.merchantNo == merchantNo || (notice.callId.isNotEmpty && notice.callId == callId);
      if (!same || phase == CallPhase.idle) return;
      if (notice.reason == 'answered' && phase != CallPhase.incoming) return;
      if (phase == CallPhase.incoming) {
        await _reset(CallPhase.idle, notice.reason == 'answered' ? '這通已由其他人接聽' : '對方已取消');
        await _promoteWaiting();
        unawaited(refreshMissed());
        return;
      }
      await _reset(CallPhase.ended, '通話已結束');
      await _promoteWaiting();
      unawaited(refreshMissed());
      return;
    }
    if (notice.merchantNo != merchantNo && merchantNo.isNotEmpty) return;
    if (notice.event == 'answered' && phase == CallPhase.dialing) {
      await _connect(notice.merchantNo);
      return;
    }
    if (notice.event == 'rejected') {
      await _reset(CallPhase.ended, '對方拒接');
      await _promoteWaiting();
    }
  }

  Future<void> catchUp() async {
    if (phase != CallPhase.incoming || session == null || merchantNo.isEmpty) return;
    try {
      final page = await api.calls();
      CallLog? row;
      for (final item in page.calls) {
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

  Future<String?> callBack(CallLog item) async {
    if (phase != CallPhase.idle && phase != CallPhase.ended) return '請先結束目前的通話';
    if (item.machineCode.isEmpty) return '這筆紀錄沒有機台';
    Hotel? hotel;
    for (final known in session?.hotels ?? const <Hotel>[]) {
      if (known.id == item.hotelId) hotel = known;
    }
    if (hotel == null) return '這間旅店不在這個帳號';
    await callMachine(hotel, Machine(code: item.machineCode, name: item.machineName, model: 0));
    return null;
  }

  Future<String> pushStatusLabel() async {
    if (_deviceToken == null || _deviceToken!.isEmpty) return '這支手機還沒拿到推播';
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      final allowed = settings.authorizationStatus == AuthorizationStatus.authorized || settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!allowed) return '通知沒有開啟，鎖屏時不會響';
    } catch (_) {
      return '通知狀態讀不到';
    }
    if (!_pushRegistered) return '這支手機還沒登記成功';
    return '這支手機可以接收來電';
  }

  Future<void> registerPush() => _registerCurrentDevice();

  Future<void> openNotificationSettings() async {
    try {
      await _lock.invokeMethod<void>('openNotifications');
    } catch (_) {}
  }

  Future<void> previewRing() async {
    if (_previewing || _busy || phase == CallPhase.incoming) return;
    _previewing = true;
    notifyListeners();
    await IncomingRing.start(tone: true);
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!_previewing) return;
    _previewing = false;
    if (phase != CallPhase.incoming) await IncomingRing.stop();
    notifyListeners();
  }

  Future<void> accept() async {
    if (phase == CallPhase.connecting || phase == CallPhase.inCall) {
      await dismissRing(callId);
      return;
    }
    if (merchantNo.isEmpty) return;
    final id = callId;
    _taken.add(id);
    media.holdPicture();
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
    await _promoteWaiting();
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
    await _promoteWaiting();
    unawaited(refreshMissed());
  }

  Future<void> rejectWaiting(WaitingCall item) async {
    waiting.removeWhere((call) => call.merchantNo == item.merchantNo);
    notifyListeners();
    if (item.merchantNo.isEmpty) return;
    _closedMerchant = item.merchantNo;
    try {
      await api.reject(item.merchantNo);
    } catch (_) {}
    await dismissRing(item.callId);
  }

  Future<void> refreshMissed() async {
    if (session == null) return;
    try {
      final page = await api.calls();
      unseenMissed = page.calls.where((item) => item.unanswered && item.createdAt > _seenAt).length;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> markHistorySeen(List<CallLog> rows) async {
    var latest = _seenAt;
    for (final item in rows) {
      if (item.unanswered && item.createdAt > latest) latest = item.createdAt;
    }
    _seenAt = latest;
    unseenMissed = 0;
    await writeSeenAt(latest);
    notifyListeners();
  }

  void toggleMute() {
    muted = !muted;
    media.setMuted(muted);
    notifyListeners();
  }

  void toggleSpeaker() {
    speaker = !speaker;
    unawaited(media.setSpeaker(speaker));
    notifyListeners();
  }

  void toggleRemote() {
    remoteControl = !remoteControl;
    notifyListeners();
  }

  void swapVideo() {
    screenLarge = !screenLarge;
    _syncFrame();
    notifyListeners();
  }

  void toggleFullscreen() {
    if (phase != CallPhase.inCall && phase != CallPhase.connecting) return;
    fullscreen = !fullscreen;
    _syncFrame();
    notifyListeners();
  }

  void _onMedia() {
    _syncFrame();
    notifyListeners();
  }

  bool? _largeLandscape() {
    if (media.hasScreen) return media.screenLandscape;
    return media.cameraLandscape;
  }

  void _syncFrame() {
    if (!fullscreen) {
      _heldLandscape = null;
      if (_chromeHidden) unawaited(_restoreChrome());
      return;
    }
    if (!_chromeHidden) {
      _chromeHidden = true;
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    }
    final landscape = _largeLandscape();
    if (landscape == null || _heldLandscape == landscape) return;
    _heldLandscape = landscape;
    unawaited(_enterChrome(landscape));
  }

  Future<void> _enterChrome(bool landscape) async {
    final token = ++_frameToken;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (token != _frameToken || !fullscreen) return;
    await SystemChrome.setPreferredOrientations(
      landscape
          ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : const [DeviceOrientation.portraitUp],
    );
  }

  Future<void> _restoreChrome() async {
    _chromeHidden = false;
    final token = ++_frameToken;
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    if (token != _frameToken) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
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
    media.holdPicture();
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
    await media.connect(ticket, _onMedia);
    if (callId.isNotEmpty) await FlutterCallkitIncoming.setCallConnected(callId);
    phase = CallPhase.inCall;
    _armCredential();
    muted = false;
    speaker = false;
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

  void _armPresence() {
    _presence?.cancel();
    _presence = Timer.periodic(const Duration(hours: 6), (_) {
      unawaited(keepAlive());
    });
  }

  void _armCredential() {
    _credential?.cancel();
    _credential = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(_refreshCredential());
    });
  }

  Future<void> _refreshCredential() async {
    if (phase != CallPhase.inCall || merchantNo.isEmpty) return;
    try {
      final result = await api.sessionFor(merchantNo);
      await media.replaceTicket(result.viewer);
    } catch (_) {}
  }

  void _hold(CallNotice notice) {
    if (notice.merchantNo.isEmpty || notice.merchantNo == merchantNo) return;
    final index = waiting.indexWhere((call) => call.merchantNo == notice.merchantNo);
    final next = WaitingCall(
      merchantNo: notice.merchantNo,
      callId: notice.callId.isNotEmpty ? notice.callId : (index >= 0 ? waiting[index].callId : ''),
      hotelId: notice.hotelId.isNotEmpty ? notice.hotelId : (index >= 0 ? waiting[index].hotelId : ''),
      machineCode: notice.machineCode.isNotEmpty ? notice.machineCode : (index >= 0 ? waiting[index].machineCode : ''),
      machineName: notice.machineName.isNotEmpty ? notice.machineName : (index >= 0 ? waiting[index].machineName : ''),
    );
    if (index >= 0) {
      waiting[index] = next;
    } else {
      waiting.add(next);
    }
  }

  void _clearWaiting() {
    waiting.clear();
  }

  bool _matchesWaiting(CallNotice notice) {
    final index = waiting.indexWhere((call) => (notice.merchantNo.isNotEmpty && call.merchantNo == notice.merchantNo) || (notice.callId.isNotEmpty && call.callId == notice.callId));
    if (index < 0) return false;
    final id = waiting[index].callId;
    waiting.removeAt(index);
    if (id.isNotEmpty) unawaited(dismissRing(id));
    return true;
  }

  Future<void> _promoteWaiting() async {
    if (waiting.isEmpty) return;
    final next = waiting.removeAt(0);
    merchantNo = next.merchantNo;
    callId = next.callId;
    hotelId = next.hotelId;
    machineCode = next.machineCode;
    machineName = next.machineName;
    phase = CallPhase.incoming;
    message = '';
    _previewing = false;
    notifyListeners();
    await IncomingRing.start(tone: true);
  }

  Future<void> _registerCurrentDevice() async {
    final token = _deviceToken;
    final platform = _platform;
    if (session == null || token == null || platform == null) return;
    try {
      await api.registerDevice(platform: platform, token: token);
      _pushRegistered = true;
    } catch (_) {
      _pushRegistered = false;
    }
    notifyListeners();
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
    _credential?.cancel();
    if (next != CallPhase.incoming) await IncomingRing.stop();
    phase = next;
    message = text;
    if (next == CallPhase.idle || next == CallPhase.ended) {
      merchantNo = '';
      callId = '';
      muted = false;
      speaker = false;
      remoteControl = false;
      screenLarge = true;
      showSmall = true;
      if (fullscreen || _chromeHidden) unawaited(_restoreChrome());
      fullscreen = false;
      _heldLandscape = null;
    }
    notifyListeners();
  }
}
