class Hotel {
  const Hotel({required this.id, required this.name});

  final String id;
  final String name;

  factory Hotel.fromJson(Map<String, dynamic> json) {
    return Hotel(id: '${json['id'] ?? ''}'.trim(), name: '${json['name'] ?? ''}'.trim());
  }
}

class Machine {
  const Machine({required this.code, required this.name, required this.model});

  final String code;
  final String name;
  final int model;

  String get label => name.isEmpty ? code : '$name（$code）';

  factory Machine.fromJson(Map<String, dynamic> json) {
    return Machine(
      code: '${json['code'] ?? ''}'.trim(),
      name: '${json['name'] ?? ''}'.trim(),
      model: json['model'] is int ? json['model'] as int : int.tryParse('${json['model']}') ?? 0,
    );
  }
}

class StaffSession {
  const StaffSession({required this.token, required this.account, required this.hotels});

  final String token;
  final String account;
  final List<Hotel> hotels;

  Map<String, dynamic> toJson() => {
        'token': token,
        'account': account,
        'hotels': hotels.map((hotel) => {'id': hotel.id, 'name': hotel.name}).toList(),
      };

  factory StaffSession.fromJson(Map<String, dynamic> json) {
    final hotels = json['hotels'];
    return StaffSession(
      token: '${json['token'] ?? ''}',
      account: '${json['account'] ?? ''}',
      hotels: hotels is List
          ? hotels.whereType<Map>().map((item) => Hotel.fromJson(Map<String, dynamic>.from(item))).where((hotel) => hotel.id.isNotEmpty).toList()
          : const [],
    );
  }
}

class CallLog {
  const CallLog({
    required this.merchantNo,
    required this.hotelId,
    required this.machineCode,
    required this.machineName,
    required this.direction,
    required this.status,
    required this.callerName,
    required this.answeredName,
    required this.endedName,
    required this.duration,
    required this.createdAt,
  });

  final String merchantNo;
  final String hotelId;
  final String machineCode;
  final String machineName;
  final String direction;
  final String status;
  final String callerName;
  final String answeredName;
  final String endedName;
  final int duration;
  final int createdAt;

  bool get unanswered {
    if (direction != 'in' || (status != 'cancelled' && status != 'rejected')) return false;
    final name = (status == 'rejected' ? endedName : answeredName).trim();
    return name.isEmpty || name == '機台' || name == machineName || name == machineCode;
  }

  String get label => machineName.isEmpty ? machineCode : machineName;

  factory CallLog.fromJson(Map<String, dynamic> json) {
    return CallLog(
      merchantNo: '${json['merchantNo'] ?? ''}',
      hotelId: '${json['hotelId'] ?? ''}',
      machineCode: '${json['machineCode'] ?? ''}',
      machineName: '${json['machineName'] ?? ''}',
      direction: '${json['direction'] ?? ''}',
      status: '${json['status'] ?? ''}',
      callerName: '${json['callerName'] ?? ''}'.trim(),
      answeredName: '${json['answeredName'] ?? ''}'.trim(),
      endedName: '${json['endedName'] ?? ''}'.trim(),
      duration: json['duration'] is int ? json['duration'] as int : int.tryParse('${json['duration']}') ?? 0,
      createdAt: json['createdAt'] is int ? json['createdAt'] as int : int.tryParse('${json['createdAt']}') ?? 0,
    );
  }
}

class ViewerTicket {
  const ViewerTicket({
    required this.clientId,
    required this.region,
    required this.channelArn,
    required this.wssEndpoint,
    required this.iceServers,
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.sessionToken,
  });

  final String clientId;
  final String region;
  final String channelArn;
  final String wssEndpoint;
  final List<Map<String, dynamic>> iceServers;
  final String accessKeyId;
  final String secretAccessKey;
  final String sessionToken;

  factory ViewerTicket.fromJson(Map<String, dynamic> json) {
    final credentials = json['credentials'] is Map ? Map<String, dynamic>.from(json['credentials'] as Map) : <String, dynamic>{};
    final ice = json['iceServers'];
    return ViewerTicket(
      clientId: '${json['clientId'] ?? ''}',
      region: '${json['region'] ?? 'ap-southeast-1'}',
      channelArn: '${json['channelArn'] ?? ''}',
      wssEndpoint: '${json['wssEndpoint'] ?? ''}',
      iceServers: ice is List ? ice.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList() : const [],
      accessKeyId: '${credentials['accessKeyId'] ?? ''}',
      secretAccessKey: '${credentials['secretAccessKey'] ?? ''}',
      sessionToken: '${credentials['sessionToken'] ?? ''}',
    );
  }
}

class CallNotice {
  const CallNotice({
    required this.event,
    required this.callId,
    required this.merchantNo,
    required this.hotelId,
    required this.machineCode,
    required this.machineName,
    this.reason = '',
  });

  final String event;
  final String callId;
  final String merchantNo;
  final String hotelId;
  final String machineCode;
  final String machineName;
  final String reason;

  String get label => machineName.isEmpty ? machineCode : '$machineName（$machineCode）';

  factory CallNotice.fromMap(Map<dynamic, dynamic> raw) {
    final extra = raw['extra'];
    final source = extra is Map ? {...raw, ...Map<dynamic, dynamic>.from(extra)} : raw;
    final handle = '${source['handle'] ?? source['number'] ?? ''}'.trim();
    final merchantNo = '${source['merchantNo'] ?? ''}'.trim().isNotEmpty ? '${source['merchantNo'] ?? ''}'.trim() : handle;
    final machineCode = '${source['machineCode'] ?? ''}'.trim();
    return CallNotice(
      event: '${source['event'] ?? ''}',
      callId: '${source['callId'] ?? source['id'] ?? ''}',
      merchantNo: merchantNo,
      hotelId: '${source['hotelId'] ?? ''}',
      machineCode: machineCode.isNotEmpty ? machineCode : (handle == merchantNo ? '' : handle),
      machineName: '${source['machineName'] ?? source['nameCaller'] ?? ''}',
      reason: '${source['reason'] ?? ''}',
    );
  }
}
