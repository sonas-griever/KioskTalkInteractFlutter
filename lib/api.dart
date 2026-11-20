import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.status = 0});

  final String message;
  final int status;

  @override
  String toString() => message;
}

class TalkApi {
  TalkApi(this.session);

  StaffSession? session;

  String? deviceToken;

  Map<String, String> get _auth => {
        'content-type': 'application/json',
        if (session != null) 'authorization': 'Bearer ${session!.token}',
      };

  Future<StaffSession> login(String account, String password) async {
    final body = await _send('POST', '/talk-login', payload: {'account': account, 'password': password}, auth: false);
    final token = body['token'];
    if (token is! String || token.isEmpty) throw ApiException('帳號或密碼不對');
    final next = StaffSession(
      token: token,
      account: body['account'] is String ? body['account'] as String : account.trim(),
      hotels: body['hotels'] is List
          ? (body['hotels'] as List).whereType<Map>().map((item) => Hotel.fromJson(Map<String, dynamic>.from(item))).toList()
          : const [],
    );
    session = next;
    return next;
  }

  Future<StaffSession> refresh(StaffSession current) async {
    final body = await _send('POST', '/talk-refresh');
    final token = body['token'];
    if (token is! String || token.isEmpty) return current;
    final hotels = body['hotels'] is List
        ? (body['hotels'] as List).whereType<Map>().map((item) => Hotel.fromJson(Map<String, dynamic>.from(item))).where((hotel) => hotel.id.isNotEmpty).toList()
        : current.hotels;
    return StaffSession(token: token, account: current.account, hotels: hotels.isEmpty ? current.hotels : hotels);
  }

  Future<({Map<String, bool> links, Set<String> registered})> machineLinks(String hotelId, List<String> codes) async {
    if (codes.isEmpty) return (links: const <String, bool>{}, registered: const <String>{});
    final body = await _send('POST', '/hotels/$hotelId/machine-links', payload: {'machines': codes});
    final rawLinks = body['links'];
    final channels = body['channels'];
    final links = <String, bool>{};
    if (rawLinks is Map) {
      for (final entry in rawLinks.entries) {
        links['${entry.key}'] = entry.value == 'on';
      }
    }
    final registered = <String>{};
    if (channels is Map) {
      for (final entry in channels.entries) {
        final value = entry.value;
        if (value == true || value == 1 || value == 'true') registered.add('${entry.key}');
      }
    }
    return (links: links, registered: registered);
  }

  Future<List<Machine>> machines(String hotelId) async {
    final body = await _send('GET', '/hotels/$hotelId/machines');
    final rows = body['machines'];
    if (rows is! List) return const [];
    return rows.whereType<Map>().map((item) => Machine.fromJson(Map<String, dynamic>.from(item))).toList();
  }

  Future<void> registerDevice({required String platform, required String token}) async {
    await _send('POST', '/devices', payload: {'platform': platform, 'token': token, 'account': session?.account ?? ''});
  }

  Future<void> removeDevice(String token) async {
    await _send('DELETE', '/devices', payload: {'token': token});
  }

  Future<({List<CallLog> calls, bool more})> calls({int? before}) async {
    final path = before == null ? '/calls' : '/calls?before=$before';
    final body = await _send('GET', path);
    final rows = body['calls'];
    final calls = rows is List
        ? rows.whereType<Map>().map((item) => CallLog.fromJson(Map<String, dynamic>.from(item))).toList()
        : <CallLog>[];
    return (calls: calls, more: body['more'] == true);
  }

  Future<CallNotice> startCall(String hotelId, String machineCode) async {
    final body = await _send('POST', '/hotels/$hotelId/machines/${Uri.encodeComponent(machineCode)}/calls');
    return CallNotice.fromMap({...body, 'event': 'dialing'});
  }

  Future<({CallNotice notice, ViewerTicket viewer})> answer(String merchantNo) async {
    final body = await _send('POST', '/calls/$merchantNo/answer', payload: {'deviceToken': deviceToken ?? ''});
    return (notice: CallNotice.fromMap({...body, 'event': 'answered'}), viewer: ViewerTicket.fromJson(_viewer(body)));
  }

  Future<void> reject(String merchantNo) async {
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _send('POST', '/calls/$merchantNo/reject');
        return;
      } catch (error) {
        last = error;
        if (error is ApiException && (error.status == 401 || error.status == 403)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    if (last is ApiException) throw last;
    throw ApiException('拒接沒有送到');
  }

  Future<void> hangup(String merchantNo) async {
    await _send('POST', '/calls/$merchantNo/hangup');
  }

  Future<({CallNotice notice, ViewerTicket viewer})> sessionFor(String merchantNo) async {
    final body = await _send('POST', '/calls/$merchantNo/session');
    return (notice: CallNotice.fromMap({...body, 'event': 'answered'}), viewer: ViewerTicket.fromJson(_viewer(body)));
  }

  Map<String, dynamic> _viewer(Map<String, dynamic> body) {
    final viewer = body['viewer'];
    if (viewer is Map) return Map<String, dynamic>.from(viewer);
    throw ApiException('沒有拿到通話憑證');
  }

  Future<Map<String, dynamic>> _send(String method, String path, {Map<String, dynamic>? payload, bool auth = true}) async {
    if (apiBase.isEmpty) throw ApiException('沒有設定 API');
    final response = http.Request(method, Uri.parse('$apiBase$path'));
    response.headers.addAll(auth ? _auth : const {});
    if (payload != null) {
      response.headers['content-type'] = 'application/json';
      response.body = jsonEncode(payload);
    }
    final result = await http.Client().send(response);
    final text = await result.stream.bytesToString();
    Map<String, dynamic> body = {};
    if (text.isNotEmpty) {
      final parsed = jsonDecode(text);
      if (parsed is Map) body = Map<String, dynamic>.from(parsed);
    }
    if (auth && result.statusCode == 401) throw ApiException('請先登入', status: 401);
    if (result.statusCode < 200 || result.statusCode >= 300) {
      throw ApiException(body['message'] is String ? body['message'] as String : '伺服器錯誤', status: result.statusCode);
    }
    return body;
  }
}
