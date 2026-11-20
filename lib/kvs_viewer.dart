import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
import 'sigv4.dart';

class KvsViewer {
  RTCVideoRenderer screenView = RTCVideoRenderer();
  RTCVideoRenderer cameraView = RTCVideoRenderer();
  var screenFrame = false;
  var cameraFrame = false;
  RTCPeerConnection? _peer;
  RTCDataChannel? control;
  RTCDataChannel? _remoteControl;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _signalSub;
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
  var _socketOpen = false;
  var _socketGen = 0;
  var _reconnects = 0;
  var _reconnecting = false;
  var recovering = false;
  Timer? _reconnectTimer;
  var closed = false;
  var speaker = false;

  int get videoWidth => screenView.videoWidth;
  int get videoHeight => screenView.videoHeight;
  int get videoRotation => screenView.value.rotation;
  bool? get screenLandscape => _landscape(videoWidth, videoHeight, videoRotation);
  bool? get cameraLandscape => _landscape(cameraView.videoWidth, cameraView.videoHeight, cameraView.value.rotation);

  bool? _landscape(int width, int height, int rotation) {
    var wide = width;
    var tall = height;
    if (rotation == 90 || rotation == 270) {
      final swap = wide;
      wide = tall;
      tall = swap;
    }
    if (wide <= 0 || tall <= 0) return null;
    return wide > tall;
  }
  bool get hasScreen => screenView.srcObject != null;
  bool get hasCamera => cameraView.srcObject != null;
  bool get controlOpen => _openChannel()?.state == RTCDataChannelState.RTCDataChannelOpen;

  void holdPicture() {
    screenFrame = false;
    cameraFrame = false;
  }

  void _blank(RTCVideoRenderer view) {
    if (view.textureId == null) return;
    view.srcObject = null;
  }

  Future<void> connect(ViewerTicket ticket, void Function() onChanged) async {
    closed = false;
    _ticket = ticket;
    _onChanged = onChanged;
    holdPicture();
    onChanged();
    await _freshViews();
    if (closed) return;
    await Helper.setAndroidAudioConfiguration(AndroidAudioConfiguration(
      manageAudioFocus: true,
      androidAudioMode: AndroidAudioMode.inCommunication,
      androidAudioFocusMode: AndroidAudioFocusMode.gain,
      androidAudioStreamType: AndroidAudioStreamType.voiceCall,
      androidAudioAttributesUsageType: AndroidAudioAttributesUsageType.voiceCommunication,
      androidAudioAttributesContentType: AndroidAudioAttributesContentType.speech,
    ));
    await Helper.setSpeakerphoneOn(speaker);
    _local = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    await _listen(ticket);
    await _offer(2);
  }

  Future<void> replaceTicket(ViewerTicket ticket) async {
    if (closed) return;
    _ticket = ticket;
    final peer = _peer;
    if (peer != null) {
      try {
        await peer.setConfiguration({
          'iceServers': ticket.iceServers,
          'sdpSemantics': 'unified-plan',
          'bundlePolicy': 'max-bundle',
        });
      } catch (error) {
        debugPrint('kvs ice config $error');
      }
    }
    if (!_socketOpen) await _reconnect();
  }

  Future<void> _listen(ViewerTicket ticket) async {
    final generation = ++_socketGen;
    await _signalSub?.cancel();
    _signalSub = null;
    _socketOpen = false;
    await _socket?.sink.close();
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
    _signalSub = _socket!.stream.listen((message) => _onSignal(ticket.clientId, '$message'), onError: (error) {
      debugPrint('kvs socket $error');
      if (generation != _socketGen || closed) return;
      _socketOpen = false;
      _scheduleReconnect(1);
    }, onDone: () {
      if (generation != _socketGen || closed) return;
      _socketOpen = false;
      _scheduleReconnect(1);
    }, cancelOnError: true);
    try {
      await _socket!.ready;
      if (generation == _socketGen && !closed) _socketOpen = true;
    } catch (error) {
      debugPrint('kvs socket ready $error');
      _socketOpen = false;
    }
  }

  void _scheduleReconnect(int seconds) {
    if (closed || _reconnects >= 6) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      unawaited(_reconnect());
    });
  }

  Future<void> _reconnect() async {
    final ticket = _ticket;
    if (closed || _reconnecting || ticket == null || _reconnects >= 6) return;
    _reconnecting = true;
    _reconnects++;
    _setRecovering(true);
    try {
      await _listen(ticket);
      if (closed) return;
      if (!_socketOpen) {
        _scheduleReconnect(2);
        return;
      }
      await _offer(2);
    } finally {
      _reconnecting = false;
    }
  }

  void _setRecovering(bool value) {
    if (recovering == value) return;
    recovering = value;
    _onChanged?.call();
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
    _peer!.onIceConnectionState = (state) {
      if (generation != _generation) return;
      _onIce(state);
    };
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

  Future<void> setSpeaker(bool on) async {
    speaker = on;
    await Helper.setSpeakerphoneOn(on);
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

  void _onIce(RTCIceConnectionState state) {
    debugPrint('kvs ice $state');
    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected || state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
      _reconnectTimer?.cancel();
      _reconnects = 0;
      _setRecovering(false);
      return;
    }
    if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
      _scheduleReconnect(2);
    } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
      _scheduleReconnect(3);
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    speaker = false;
    _generation++;
    _socketGen++;
    _reconnectTimer?.cancel();
    _setRecovering(false);
    await _signalSub?.cancel();
    _signalSub = null;
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
    holdPicture();
    _onChanged?.call();
    _blank(screenView);
    _blank(cameraView);
    _videos.clear();
    _remoteStreams.clear();
  }

  Future<void> _freshViews() async {
    final previousScreen = _viewsReady ? screenView : null;
    final previousCamera = _viewsReady ? cameraView : null;
    await SchedulerBinding.instance.endOfFrame;
    if (closed) return;
    final nextScreen = RTCVideoRenderer();
    final nextCamera = RTCVideoRenderer();
    await nextScreen.initialize();
    await nextCamera.initialize();
    if (closed) {
      await nextScreen.dispose();
      await nextCamera.dispose();
      return;
    }
    _arm(nextScreen, true);
    _arm(nextCamera, false);
    screenView = nextScreen;
    cameraView = nextCamera;
    _viewsReady = true;
    _onChanged?.call();
    if (previousScreen != null) {
      previousScreen.srcObject = null;
      await previousScreen.dispose();
    }
    if (previousCamera != null) {
      previousCamera.srcObject = null;
      await previousCamera.dispose();
    }
  }

  void _arm(RTCVideoRenderer view, bool screen) {
    view.onResize = () {
      if (view.videoWidth > 0 && view.videoHeight > 0) _shown(view, screen);
      _onChanged?.call();
    };
    view.onFirstFrameRendered = () => _shown(view, screen);
  }

  void _shown(RTCVideoRenderer view, bool screen) {
    if (screen) {
      if (view != screenView || screenFrame) return;
      screenFrame = true;
    } else {
      if (view != cameraView || cameraFrame) return;
      cameraFrame = true;
    }
    _onChanged?.call();
  }

  Future<void> _showTrack(RTCTrackEvent event, void Function() onChanged) async {
    final track = event.track;
    if (track.kind == 'audio') {
      track.enabled = true;
      await Helper.setVolume(1, track);
      await Helper.setSpeakerphoneOn(speaker);
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
