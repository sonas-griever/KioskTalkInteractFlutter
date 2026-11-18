import 'dart:convert';

import 'package:crypto/crypto.dart';

String signKvsWebSocket({
  required String wssEndpoint,
  required String channelArn,
  required String clientId,
  required String accessKeyId,
  required String secretAccessKey,
  required String sessionToken,
  required String region,
}) {
  final endpoint = Uri.parse(wssEndpoint);
  final now = DateTime.now().toUtc();
  final dateStamp = '${now.year}${_two(now.month)}${_two(now.day)}';
  final amzDate = '${dateStamp}T${_two(now.hour)}${_two(now.minute)}${_two(now.second)}Z';
  final scope = '$dateStamp/$region/kinesisvideo/aws4_request';
  final params = <String, String>{
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-ChannelARN': channelArn,
    'X-Amz-ClientId': clientId,
    'X-Amz-Credential': '$accessKeyId/$scope',
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': '300',
    'X-Amz-Security-Token': sessionToken,
    'X-Amz-SignedHeaders': 'host',
  };
  final names = params.keys.toList()..sort();
  final canonicalQuery = names.map((name) => '${_awsEncode(name)}=${_awsEncode(params[name]!)}').join('&');
  final path = endpoint.path.isEmpty ? '/' : endpoint.path;
  final port = endpoint.hasPort ? endpoint.port : 443;
  final canonical = [
    'GET',
    path,
    canonicalQuery,
    'host:${endpoint.host}',
    '',
    'host',
    sha256.convert(utf8.encode('')).toString(),
  ].join('\n');
  final stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256.convert(utf8.encode(canonical)).toString()].join('\n');
  final signingKey = _hmac(
    _hmac(_hmac(_hmac(utf8.encode('AWS4$secretAccessKey'), dateStamp), region), 'kinesisvideo'),
    'aws4_request',
  );
  final signature = Hmac(sha256, signingKey).convert(utf8.encode(stringToSign)).toString();
  return '${endpoint.scheme}://${endpoint.host}:$port$path?$canonicalQuery&X-Amz-Signature=$signature';
}

List<int> _hmac(List<int> key, String data) => Hmac(sha256, key).convert(utf8.encode(data)).bytes;

String _awsEncode(String value) {
  final buffer = StringBuffer();
  for (final unit in utf8.encode(value)) {
    final unreserved = (unit >= 0x41 && unit <= 0x5A) ||
        (unit >= 0x61 && unit <= 0x7A) ||
        (unit >= 0x30 && unit <= 0x39) ||
        unit == 0x2D ||
        unit == 0x5F ||
        unit == 0x2E ||
        unit == 0x7E;
    if (unreserved) {
      buffer.writeCharCode(unit);
    } else {
      buffer.write('%${unit.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return buffer.toString();
}

String _two(int value) => value.toString().padLeft(2, '0');
