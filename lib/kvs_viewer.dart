import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
import 'sigv4.dart';

class KvsViewer {
  final screenView = RTCVideoRenderer();
  final cameraView = RTCVideoRenderer();
  RTCPeerConnection? _peer;
  RTCDataChannel? control;
  RTCDataChannel? _remoteControl;
  WebSocketChannel? _socket;
  MediaStream? _local;
  final List<MediaStream> _remoteStreams = [];
  final List<RTCIceCandidate> _pendingIce = [];
  ViewerTicket? _ticket;
  void Function()? _onChanged;
  final List<MediaStream> _videos = [];
  var _generation = 0;
  var _videoCount = 0;
  var _remoteReady = false;
  var _viewsReady = false;
  var closed = false;

  int get videoWidth => screenView.videoWidth;
  int get videoHeight => screenView.videoHeight;
  int get videoRotation => screenView.value.rotation;
  bool get hasScreen => screenView.srcObject != null;
  bool get hasCamera => cameraView.srcObject != null;
  bool get controlOpen => _openChannel()?.state == RTCDataChannelState.RTCDataChannelOpen;

  Future<void> connect(ViewerTicket ticket, void Function() onChanged) async {
    if (!_viewsReady) {
      await screenView.initialize();
      await cameraView.initialize();
      screenView.onResize = onChanged;
      _viewsReady = true;
    }
    closed = false;
    _ticket = ticket;
    _onChanged = onChanged;
    await Helper.setAndroidAudioConfiguration(AndroidAudioConfiguration(
      manageAudioFocus: true,
      androidAudioMode: AndroidAudioMode.inCommunication,
      androidAudioFocusMode: AndroidAudioFocusMode.gain,
      androidAudioStreamType: AndroidAudioStreamType.voiceCall,
      androidAudioAttributesUsageType: AndroidAudioAttributesUsageType.voiceCommunication,
      androidAudioAttributesContentType: AndroidAudioAttributesContentType.speech,
    ));
    await Helper.setSpeakerphoneOn(true);
    _local = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    final url = signKvsWebSocket(
      wssEndpoint: ticket.wssEndpoint,
      channelArn: ticket.channelArn,
      clientId: ticket.clientId,
      accessKeyId: ticket.accessKeyId,
      secretAccessKey: ticket.secretAccessKey,
      sessionToken: ticket.sessionToken,
      region: ticket.region,
    );
    _socket = WebSocketChannel.connect(Uri.parse(url));
    _socket!.stream.listen((message) => _onSignal(ticket.clientId, '$message'), onError: (error) {
      debugPrint('kvs socket $error');
    }, cancelOnError: true);
    try {
      await _socket!.ready;
    } catch (error) {
      debugPrint('kvs socket ready $error');
    }
    await _offer(2);
  }

  Future<void> _offer(int videos) async {
    final generation = ++_generation;
    final ticket = _ticket;
    final onChanged = _onChanged;
    if (ticket == null || onChanged == null || closed) return;
    _videoCount = videos;
    _remoteReady = false;
    _pendingIce.clear();
    _videos.clear();
    screenView.srcObject = null;
    cameraView.srcObject = null;
    await control?.close();
    control = null;
    _remoteControl = null;
    await _peer?.close();
    if (closed || generation != _generation) return;
    _peer = await createPeerConnection({
      'iceServers': ticket.iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
    });
    for (var index = 0; index < videos; index++) {
      await _peer!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
    }
    for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      await _peer!.addTrack(track, _local!);
    }
    control = await _peer!.createDataChannel('data-channel-of-0', RTCDataChannelInit());
    _watchChannel(control!);
    _peer!.onDataChannel = (channel) {
      if (generation != _generation) return;
      _remoteControl = channel;
      _watchChannel(channel);
      onChanged();
    };
    _peer!.onTrack = (event) {
      if (generation != _generation) return;
      unawaited(_showTrack(event, onChanged));
    };
    _peer!.onIceConnectionState = (state) => debugPrint('kvs ice $state');
    _peer!.onIceCandidate = (candidate) {
      if (generation != _generation || candidate.candidate == null || candidate.candidate!.isEmpty) return;
      _sendIce(ticket.clientId, candidate);
    };
    final offer = await _peer!.createOffer();
    if (closed || generation != _generation) return;
    debugPrint('kvs offer videos=$videos');
    await _peer!.setLocalDescription(offer);
    _send('SDP_OFFER', ticket.clientId, '', {'type': 'offer', 'sdp': offer.sdp});
  }

  void setMuted(bool muted) {
    for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  void sendClick(double x, double y) {
    final channel = _openChannel();
    if (channel == null) {
      debugPrint('kvs click dropped');
      return;
    }
    channel.send(RTCDataChannelMessage(jsonEncode({'type': 'click', 'x': x, 'y': y})));
  }

  void _watchChannel(RTCDataChannel channel) {
    channel.onDataChannelState = (state) {
      debugPrint('kvs channel ${channel.label} $state');
      _onChanged?.call();
    };
  }

  RTCDataChannel? _openChannel() {
    for (final channel in [control, _remoteControl]) {
      if (channel != null && channel.state == RTCDataChannelState.RTCDataChannelOpen) return channel;
    }
    return control ?? _remoteControl;
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    _generation++;
    await _socket?.sink.close();
    _socket = null;
    await control?.close();
    control = null;
    _remoteControl = null;
    await _peer?.close();
    _peer = null;
    for (final track in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _local?.dispose();
    _local = null;
    screenView.srcObject = null;
    cameraView.srcObject = null;
    _videos.clear();
    _remoteStreams.clear();
  }

  Future<void> _showTrack(RTCTrackEvent event, void Function() onChanged) async {
    final track = event.track;
    if (track.kind == 'audio') {
      track.enabled = true;
      await Helper.setVolume(1, track);
      await Helper.setSpeakerphoneOn(true);
      debugPrint('kvs audio ${track.id}');
    } else if (track.kind == 'video') {
      final id = track.id ?? '';
      final solo = await createLocalMediaStream('view-$id');
      await solo.addTrack(track);
      _remoteStreams.add(solo);
      _videos.add(solo);
      debugPrint('kvs video $id');
      if (_videos.length == 1) {
        screenView.srcObject = solo;
      } else {
        cameraView.srcObject = _videos.first;
        screenView.srcObject = solo;
      }
    }
    onChanged();
  }

  void _onSignal(String clientId, String raw) {
    if (!raw.contains('messagePayload')) return;
    final parsed = jsonDecode(raw);
    if (parsed is! Map) return;
    final message = Map<String, dynamic>.from(parsed);
    final type = '${message['messageType'] ?? ''}'.toUpperCase();
    final payload = utf8.decode(base64.decode(_pad('${message['messagePayload'] ?? ''}')));
    final body = jsonDecode(payload);
    if (body is! Map) return;
    final data = Map<String, dynamic>.from(body);
    if (type == 'SDP_ANSWER') {
      unawaited(_applyAnswer('${data['sdp'] ?? ''}'));
    } else if (type == 'SDP_OFFER') {
      unawaited(_applyOffer(clientId, '${data['sdp'] ?? ''}'));
    } else if (type == 'ICE_CANDIDATE') {
      unawaited(_addIce(RTCIceCandidate('${data['candidate'] ?? ''}', '${data['sdpMid'] ?? ''}', _line(data['sdpMLineIndex']))));
    }
  }

  Future<void> _applyAnswer(String sdp) async {
    final peer = _peer;
    if (peer == null || sdp.isEmpty) return;
    try {
      await peer.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      _remoteReady = true;
      await _flushIce();
      debugPrint('kvs answer videos=$_videoCount');
    } catch (error) {
      debugPrint('kvs answer failed $error');
    }
  }

  Future<void> _applyOffer(String clientId, String sdp) async {
    final peer = _peer;
    if (peer == null || sdp.isEmpty) return;
    await peer.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final answer = await peer.createAnswer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': 1});
    await peer.setLocalDescription(answer);
    _send('SDP_ANSWER', '', clientId, {'type': 'answer', 'sdp': answer.sdp});
    _remoteReady = true;
    await _flushIce();
  }

  Future<void> _addIce(RTCIceCandidate candidate) async {
    if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
    if (!_remoteReady || _peer == null) {
      _pendingIce.add(candidate);
      return;
    }
    await _peer!.addCandidate(candidate);
  }

  Future<void> _flushIce() async {
    final peer = _peer;
    if (peer == null) return;
    for (final candidate in _pendingIce) {
      await peer.addCandidate(candidate);
    }
    _pendingIce.clear();
  }

  void _sendIce(String clientId, RTCIceCandidate candidate) {
    _send('ICE_CANDIDATE', clientId, '', {
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
  }

  void _send(String action, String senderClientId, String recipientClientId, Map<String, dynamic> payload) {
    _socket?.sink.add(jsonEncode({
      'action': action,
      'messagePayload': base64.encode(utf8.encode(jsonEncode(payload))),
      'recipientClientId': recipientClientId,
      'senderClientId': senderClientId,
    }));
  }

  int _line(Object? value) {
    if (value is int) return value;
    return int.tryParse('$value') ?? 0;
  }

  String _pad(String value) {
    final normalized = value.replaceAll('-', '+').replaceAll('_', '/');
    final mod = normalized.length % 4;
    if (mod == 0) return normalized;
    return normalized.padRight(normalized.length + (4 - mod), '=');
  }
}
