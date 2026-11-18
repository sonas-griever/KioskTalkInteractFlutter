import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'api.dart';
import 'models.dart';
import 'push_ring.dart';
import 'session_store.dart';
import 'talk_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final talk = TalkController();
  await talk.restore();
  await startPush(onNotice: talk.onNotice, onToken: talk.onDeviceToken);
  runApp(TalkApp(talk: talk));
}

class TalkApp extends StatelessWidget {
  const TalkApp({super.key, required this.talk});

  final TalkController talk;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '櫃台通話',
      navigatorKey: TalkShell.navigatorKey,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1C1915),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFC6A15B),
          onPrimary: Color(0xFF1C1915),
          surface: Color(0xFF2A2622),
          onSurface: Color(0xFFF4EDE2),
          secondary: Color(0xFF8A8175),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF1C1915),
          indicatorColor: const Color(0xFFC6A15B).withValues(alpha: 0.28),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(fontSize: 12, color: selected ? const Color(0xFFC6A15B) : const Color(0xFF8A8175));
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(color: selected ? const Color(0xFFC6A15B) : const Color(0xFF8A8175));
          }),
        ),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1C1915), foregroundColor: Color(0xFFF4EDE2)),
      ),
      home: TalkShell(talk: talk),
    );
  }
}

class TalkShell extends StatefulWidget {
  const TalkShell({super.key, required this.talk});

  static final navigatorKey = GlobalKey<NavigatorState>();
  final TalkController talk;

  @override
  State<TalkShell> createState() => _TalkShellState();
}

class _TalkShellState extends State<TalkShell> with WidgetsBindingObserver {
  var _callOpen = false;
  var _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.talk.addListener(_onTalk);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.talk.removeListener(_onTalk);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.talk.catchUp();
  }

  void _onTalk() {
    final phase = widget.talk.phase;
    final open = phase == CallPhase.dialing || phase == CallPhase.connecting || phase == CallPhase.inCall;
    const MethodChannel('kiosk_talk/lock').invokeMethod<void>('callVisible', {'visible': open});
    if (open && !_callOpen) {
      _callOpen = true;
      TalkShell.navigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => CallPage(talk: widget.talk))).whenComplete(() {
        _callOpen = false;
      });
    }
    if (!open && _callOpen) {
      _callOpen = false;
      TalkShell.navigatorKey.currentState?.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.talk,
      builder: (context, _) {
        final session = widget.talk.session;
        if (session == null) return LoginPage(talk: widget.talk);
        return Scaffold(
          body: Stack(
            children: [
              switch (_tab) {
                0 => DeskPage(talk: widget.talk, session: session),
                1 => HistoryPage(talk: widget.talk),
                2 => SettingsPage(talk: widget.talk, session: session),
                _ => const MorePage(),
              },
              if (widget.talk.phase == CallPhase.incoming)
                Positioned(left: 16, right: 16, top: 0, child: SafeArea(child: _incomingBanner())),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (index) => setState(() => _tab = index),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.call), label: '櫃台通話'),
              NavigationDestination(icon: Icon(Icons.history), label: '來電紀錄'),
              NavigationDestination(icon: Icon(Icons.settings), label: '設定'),
              NavigationDestination(icon: Icon(Icons.more_horiz), label: '其他'),
            ],
          ),
        );
      },
    );
  }

  Widget _incomingBanner() {
    final talk = widget.talk;
    return Material(
      color: const Color(0xFF2A2622),
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFC6A15B), width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('機台來電', style: TextStyle(color: Color(0xFFF4EDE2), fontSize: 22)),
            const SizedBox(height: 4),
            Text(talk.peerLabel, style: const TextStyle(color: Color(0xFFC6A15B), fontSize: 16)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: talk.decline, child: const Text('拒接'))),
                const SizedBox(width: 12),
                Expanded(child: FilledButton(onPressed: talk.accept, child: const Text('接聽'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.talk});

  final TalkController talk;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  var _busy = false;
  var _error = '';

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await widget.talk.login(_account.text, _password.text);
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = '帳號或密碼不對');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('測試環境', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                Text('櫃台通話', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                const Text('使用掌櫃或員工帳號登入。'),
                const SizedBox(height: 24),
                TextField(controller: _account, decoration: const InputDecoration(labelText: '帳號'), textInputAction: TextInputAction.next),
                const SizedBox(height: 12),
                TextField(controller: _password, decoration: const InputDecoration(labelText: '密碼'), obscureText: true, onSubmitted: (_) => _submit()),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(_error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 20),
                FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? '登入中…' : '登入')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DeskPage extends StatefulWidget {
  const DeskPage({super.key, required this.talk, required this.session});

  final TalkController talk;
  final StaffSession session;

  @override
  State<DeskPage> createState() => _DeskPageState();
}

class _DeskPageState extends State<DeskPage> {
  static const _ink = Color(0xFF1C1915);
  static const _card = Color(0xFF2A2622);
  static const _gold = Color(0xFFC6A15B);
  static const _paper = Color(0xFFF4EDE2);
  static const _muted = Color(0xFF8A8175);

  String? _hotelId;
  List<Machine>? _machines;
  Map<String, bool> _links = const {};
  var _linksReady = false;
  var _error = '';

  @override
  void initState() {
    super.initState();
    final hotels = widget.session.hotels;
    if (hotels.length == 1) _load(hotels.first.id);
  }

  @override
  void didUpdateWidget(DeskPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final talk = widget.talk;
    if (talk.phase != CallPhase.incoming || talk.hotelId.isEmpty || talk.hotelId == _hotelId) return;
    if (!widget.session.hotels.any((hotel) => hotel.id == talk.hotelId)) return;
    _load(talk.hotelId);
  }

  Hotel? get _hotel {
    for (final hotel in widget.session.hotels) {
      if (hotel.id == _hotelId) return hotel;
    }
    return null;
  }

  Future<void> _load(String hotelId) async {
    setState(() {
      _hotelId = hotelId;
      _machines = null;
      _links = const {};
      _linksReady = false;
      _error = '';
    });
    try {
      final machines = await widget.talk.api.machines(hotelId);
      if (!mounted || _hotelId != hotelId) return;
      setState(() => _machines = machines);
      final links = await widget.talk.api.machineLinks(hotelId, machines.map((item) => item.code).toList());
      if (!mounted || _hotelId != hotelId) return;
      setState(() {
        _links = links;
        _linksReady = true;
      });
    } on ApiException catch (error) {
      if (error.status == 401) {
        await clearSession();
        widget.talk.clearLocalSession();
        return;
      }
      if (!mounted || _hotelId != hotelId) return;
      setState(() {
        _error = error.message;
        if (_machines != null) _linksReady = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hotels = widget.session.hotels;
    final hotel = _hotel;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('櫃台通話'),
            if (hotel != null) Text(hotel.name, style: const TextStyle(color: _gold, fontSize: 13)),
          ],
        ),
        actions: [
          if (_hotelId != null) IconButton(onPressed: () => _load(_hotelId!), icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hotels.length > 1)
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final item in hotels)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(item.name),
                        selected: item.id == _hotelId,
                        onSelected: (_) => _load(item.id),
                      ),
                    ),
                ],
              ),
            ),
          if (widget.talk.message.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 0), child: Text(widget.talk.message)),
          if (_error.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 0), child: Text(_error, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          Expanded(child: _machinesView()),
        ],
        ),
      ),
    );
  }

  Widget _machinesView() {
    if (_hotelId == null) return const Center(child: Text('選擇旅店', style: TextStyle(color: _paper, fontSize: 22)));
    final machines = _machines;
    if (machines == null && _error.isEmpty) return const Center(child: CircularProgressIndicator(color: _gold));
    if (machines == null) return const SizedBox.shrink();
    if (machines.isEmpty) return const Center(child: Text('這間旅店沒有機台', style: TextStyle(color: _paper, fontSize: 20)));
    if (machines.length <= 2) {
      return LayoutBuilder(
        builder: (context, constraints) {
          const gap = 12.0;
          final cardHeight = (constraints.maxHeight - 32 - gap) / 2;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SizedBox(height: cardHeight, child: _machineCard(machines[0], large: true)),
                if (machines.length == 2) ...[
                  const SizedBox(height: gap),
                  SizedBox(height: cardHeight, child: _machineCard(machines[1], large: true)),
                ],
              ],
            ),
          );
        },
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.92),
      itemCount: machines.length,
      itemBuilder: (context, index) => _machineCard(machines[index], large: false),
    );
  }

  String? _callLabel(Machine machine) {
    final talk = widget.talk;
    if (talk.hotelId != _hotelId || talk.machineCode != machine.code) return null;
    return switch (talk.phase) {
      CallPhase.dialing => '撥號中',
      CallPhase.connecting || CallPhase.inCall => '通話中',
      CallPhase.incoming => '來電',
      _ => null,
    };
  }

  Widget _machineCard(Machine machine, {required bool large}) {
    final online = _links[machine.code];
    final callLabel = _callLabel(machine);
    final idle = widget.talk.phase == CallPhase.idle || widget.talk.phase == CallPhase.ended;
    final ready = _linksReady && online == true && idle && callLabel == null;
    final hotel = _hotel;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: callLabel == null ? _gold.withValues(alpha: 0.45) : _gold, width: callLabel == null ? 1 : 2),
      ),
      child: Padding(
        padding: EdgeInsets.all(large ? 20 : 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(machine.name.isEmpty ? machine.code : machine.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: _paper, fontSize: large ? 28 : 18, fontWeight: FontWeight.w600)),
            if (machine.name.isNotEmpty) Text(machine.code, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _muted, fontSize: large ? 14 : 12)),
            const SizedBox(height: 10),
            _status(online, callLabel),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: large
                  ? FilledButton.icon(
                      onPressed: ready && hotel != null ? () => widget.talk.callMachine(hotel, machine) : null,
                      icon: const Icon(Icons.call),
                      label: const Text('撥打'),
                    )
                  : IconButton.filled(
                      onPressed: ready && hotel != null ? () => widget.talk.callMachine(hotel, machine) : null,
                      icon: const Icon(Icons.call),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _status(bool? online, String? callLabel) {
    final color = callLabel != null || online == true ? _gold : _muted;
    final text = callLabel ?? (online == null ? '確認中' : (online ? '線上' : '未連線'));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: _ink, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.talk});

  final TalkController talk;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<CallLog>? _rows;
  var _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = '';
    });
    try {
      final rows = await widget.talk.api.calls();
      if (mounted) setState(() => _rows = rows);
    } on ApiException catch (error) {
      if (error.status == 401) {
        await clearSession();
        widget.talk.clearLocalSession();
        return;
      }
      if (mounted) {
        setState(() {
          _error = error.message;
          _rows ??= [];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('來電紀錄'), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: rows == null
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFC6A15B)))
          : rows.isEmpty
              ? Center(child: Text(_error.isEmpty ? '還沒有通話紀錄' : _error, style: const TextStyle(color: Color(0xFFF4EDE2), fontSize: 18)))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: rows.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => _row(rows[index]),
                ),
    );
  }

  Widget _row(CallLog item) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF2A2622),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFC6A15B).withValues(alpha: 0.35)),
      ),
      child: ListTile(
        title: Text(item.label, style: const TextStyle(color: Color(0xFFF4EDE2))),
        subtitle: Text(_detail(item), style: const TextStyle(color: Color(0xFF8A8175))),
      ),
    );
  }

  String _detail(CallLog item) {
    final bits = <String>[item.direction == 'in' ? '撥入' : '撥出', _statusText(item)];
    if (item.answeredName.isNotEmpty) bits.add(item.answeredName);
    final length = _length(item.duration);
    if (length.isNotEmpty) bits.add(length);
    final when = _when(item.createdAt);
    if (when.isNotEmpty) bits.add(when);
    return bits.join(' · ');
  }

  String _statusText(CallLog item) {
    final inbound = item.direction == 'in';
    return switch (item.status) {
      'ringing' => inbound ? '來電中' : '撥號中',
      'answered' => '通話中',
      'rejected' => inbound ? '已拒接' : '對方拒接',
      _ => '已結束',
    };
  }

  String _length(int seconds) {
    if (seconds <= 0) return '';
    final minutes = seconds ~/ 60;
    final remain = seconds % 60;
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      return '$hours:${(minutes % 60).toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
  }

  String _when(int ms) {
    if (ms <= 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.talk, required this.session});

  final TalkController talk;
  final StaffSession session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('帳號', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: const Color(0xFF8A8175))),
          const SizedBox(height: 6),
          Text(session.account, style: const TextStyle(color: Color(0xFFF4EDE2), fontSize: 22)),
          const SizedBox(height: 28),
          FilledButton(onPressed: talk.logout, child: const Text('登出')),
        ],
      ),
    );
  }
}

class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('其他')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          _MoreItem(title: '測試環境', body: '這支 App 目前連的是測試環境。'),
          _MoreItem(title: '連線狀態', body: '線上的機台才能撥打。未連線時按鈕會停用。'),
          _MoreItem(title: '遠端操作', body: '通話中要先按開啟遠端操作，點遠端畫面才會送到機台。'),
        ],
      ),
    );
  }
}

class _MoreItem extends StatelessWidget {
  const _MoreItem({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF2A2622),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFC6A15B).withValues(alpha: 0.35)),
        ),
        child: ListTile(
          title: Text(title, style: const TextStyle(color: Color(0xFFF4EDE2))),
          subtitle: Text(body, style: const TextStyle(color: Color(0xFF8A8175))),
        ),
      ),
    );
  }
}

class CallPage extends StatelessWidget {
  const CallPage({super.key, required this.talk});

  final TalkController talk;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: talk,
      builder: (context, _) {
        final phase = talk.phase;
        return PopScope(
          canPop: phase == CallPhase.idle || phase == CallPhase.ended,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (phase == CallPhase.incoming) {
              talk.decline();
            } else {
              talk.hangup();
            }
          },
          child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(talk.peerLabel.isEmpty ? '通話' : talk.peerLabel)),
          body: Column(
            children: [
              Expanded(child: _body(context, phase)),
              if (talk.message.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(talk.message, style: const TextStyle(color: Colors.white))),
              SafeArea(child: _actions(phase)),
            ],
          ),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, CallPhase phase) {
    if (phase == CallPhase.inCall || phase == CallPhase.connecting) {
      final media = talk.media;
      final both = media.hasScreen && media.hasCamera;
      final screen = _screenView();
      final camera = RTCVideoView(media.cameraView, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
      final largeIsScreen = media.hasScreen && (!media.hasCamera || talk.screenLarge);
      final large = largeIsScreen ? screen : camera;
      final small = largeIsScreen ? camera : screen;
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: large),
          if (both && talk.showSmall)
            Positioned(
              right: 16,
              top: 16,
              width: 120,
              height: 168,
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: Colors.white54)),
                child: small,
              ),
            ),
        ],
      );
    }
    final text = switch (phase) {
      CallPhase.dialing => '撥號中…',
      CallPhase.incoming => '機台來電',
      CallPhase.ended => talk.message.isEmpty ? '通話結束' : talk.message,
      _ => '準備通話',
    };
    return Center(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 28)));
  }

  Widget _screenView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTapUp: (details) => _tap(details.localPosition, constraints.biggest),
          child: RTCVideoView(talk.media.screenView, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
        );
      },
    );
  }

  void _tap(Offset local, Size size) {
    var width = talk.media.videoWidth.toDouble();
    var height = talk.media.videoHeight.toDouble();
    final rotation = talk.media.videoRotation;
    if (rotation == 90 || rotation == 270) {
      final swap = width;
      width = height;
      height = swap;
    }
    double x;
    double y;
    if (width <= 0 || height <= 0 || size.width <= 0 || size.height <= 0) {
      if (size.width <= 0 || size.height <= 0) return;
      x = local.dx / size.width;
      y = local.dy / size.height;
    } else {
      final scale = (size.width / width) < (size.height / height) ? size.width / width : size.height / height;
      final drawnWidth = width * scale;
      final drawnHeight = height * scale;
      final left = (size.width - drawnWidth) / 2;
      final top = (size.height - drawnHeight) / 2;
      x = (local.dx - left) / drawnWidth;
      y = (local.dy - top) / drawnHeight;
    }
    if (x < 0 || y < 0 || x > 1 || y > 1) return;
    talk.tapVideo(x, y);
  }

  Widget _actions(CallPhase phase) {
    final live = phase == CallPhase.inCall;
    if (phase == CallPhase.incoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _roundAction(icon: Icons.call_end, tip: '拒接', onPressed: talk.decline, background: const Color(0xFF8C3A3A)),
          _roundAction(icon: Icons.call, tip: '接聽', onPressed: talk.accept, background: const Color(0xFFC6A15B), foreground: const Color(0xFF1C1915)),
        ],
      );
    }
    if (phase == CallPhase.ended) {
      return _roundAction(icon: Icons.close, tip: '關閉', onPressed: () => talk.hangup(message: ''));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _roundAction(icon: talk.muted ? Icons.mic_off : Icons.mic, tip: talk.muted ? '取消靜音' : '靜音', onPressed: live ? talk.toggleMute : null, background: talk.muted ? const Color(0xFFC6A15B) : const Color(0xFF2A2622), foreground: talk.muted ? const Color(0xFF1C1915) : Colors.white),
          _roundAction(icon: Icons.touch_app, tip: talk.remoteControl ? '關閉遠端操作' : '開啟遠端操作', onPressed: live ? talk.toggleRemote : null, background: talk.remoteControl ? const Color(0xFFC6A15B) : const Color(0xFF2A2622), foreground: talk.remoteControl ? const Color(0xFF1C1915) : Colors.white),
          if (talk.media.hasScreen && talk.media.hasCamera) ...[
            _roundAction(icon: Icons.swap_horiz, tip: '切換畫面', onPressed: talk.swapVideo),
            _roundAction(icon: talk.showSmall ? Icons.picture_in_picture_alt : Icons.picture_in_picture, tip: talk.showSmall ? '隱藏小畫面' : '顯示小畫面', onPressed: talk.toggleSmall),
          ],
          _roundAction(icon: Icons.call_end, tip: '掛斷', onPressed: talk.hangup, background: const Color(0xFF8C3A3A)),
        ],
      ),
    );
  }

  Widget _roundAction({
    required IconData icon,
    required String tip,
    required VoidCallback? onPressed,
    Color background = const Color(0xFF2A2622),
    Color foreground = Colors.white,
  }) {
    return IconButton(
      tooltip: tip,
      onPressed: onPressed,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        disabledBackgroundColor: const Color(0xFF2A2622),
        disabledForegroundColor: Colors.white38,
        fixedSize: const Size(56, 56),
        iconSize: 26,
      ),
    );
  }
}
