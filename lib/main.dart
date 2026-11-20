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
  String? _deskHotelId;

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
    if (state == AppLifecycleState.resumed) {
      widget.talk.catchUp();
      widget.talk.keepAlive();
      widget.talk.refreshMissed();
    }
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
        if (session == null) {
          _deskHotelId = null;
          return LoginPage(talk: widget.talk);
        }
        final chosen = session.hotels.any((hotel) => hotel.id == _deskHotelId) ? _deskHotelId : null;
        final deskHotelId = chosen ?? (session.hotels.isNotEmpty ? session.hotels.first.id : null);
        return Scaffold(
          body: Stack(
            children: [
              switch (_tab) {
                0 => DeskPage(
                    talk: widget.talk,
                    session: session,
                    initialHotelId: deskHotelId,
                    onHotelChanged: (id) {
                      if (_deskHotelId == id) return;
                      setState(() => _deskHotelId = id);
                    },
                  ),
                1 => HistoryPage(talk: widget.talk),
                2 => SettingsPage(talk: widget.talk, session: session),
                _ => const MorePage(),
              },
              if (widget.talk.phase == CallPhase.incoming || widget.talk.hasWaiting)
                Positioned(left: 16, right: 16, top: 0, child: SafeArea(child: _incomingBanner())),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (index) => setState(() => _tab = index),
            destinations: [
              const NavigationDestination(icon: Icon(Icons.call), label: '櫃台通話'),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: widget.talk.unseenMissed > 0,
                  backgroundColor: const Color(0xFF8C3A3A),
                  label: Text(widget.talk.unseenMissed > 99 ? '99+' : '${widget.talk.unseenMissed}'),
                  child: const Icon(Icons.history),
                ),
                label: '來電紀錄',
              ),
              const NavigationDestination(icon: Icon(Icons.settings), label: '設定'),
              const NavigationDestination(icon: Icon(Icons.more_horiz), label: '其他'),
            ],
          ),
        );
      },
    );
  }

  String _incomingPlace(TalkController talk, String hotelId, String machine) {
    final hotel = talk.hotelName(hotelId);
    if (hotel.isEmpty) return machine;
    return '$hotel　$machine';
  }

  Widget _incomingBanner() {
    final talk = widget.talk;
    const ink = Color(0xFF1C1914);
    const accent = Color(0xFF5C574E);
    final rejectStyle = OutlinedButton.styleFrom(foregroundColor: ink, backgroundColor: const Color(0xFFEFEAE0), side: const BorderSide(color: Color(0xFFCFC6B6)));
    final answerStyle = FilledButton.styleFrom(backgroundColor: const Color(0xFFC9974A), foregroundColor: const Color(0xFF2A1C0C));
    return Material(
      color: const Color(0xFFF7F4EE),
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE4DCCB)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('機台來電', style: TextStyle(color: ink, fontSize: 22, fontWeight: FontWeight.w700)),
            if (talk.hotelName(talk.hotelId).isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(talk.hotelName(talk.hotelId), style: const TextStyle(color: ink, fontSize: 16, fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 4),
            Text(talk.peerLabel, style: const TextStyle(color: accent, fontSize: 16)),
            const SizedBox(height: 12),
            if (talk.phase == CallPhase.incoming) ...[
              Row(
                children: [
                  Expanded(child: OutlinedButton(onPressed: talk.decline, style: rejectStyle, child: const Text('拒接'))),
                  const SizedBox(width: 12),
                  Expanded(child: FilledButton(onPressed: talk.accept, style: answerStyle, child: const Text('接聽'))),
                ],
              ),
            ],
            for (final item in talk.waiting) ...[
              const SizedBox(height: 12),
              Text(_incomingPlace(talk, item.hotelId, item.label), style: const TextStyle(color: accent, fontSize: 16)),
              const SizedBox(height: 4),
              const Text('另一通來電。要接這通，請先處理目前這通', style: TextStyle(color: accent, fontSize: 14)),
              Align(alignment: Alignment.centerRight, child: OutlinedButton(onPressed: () => talk.rejectWaiting(item), style: rejectStyle, child: const Text('拒接'))),
            ],
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
  var _showPassword = false;

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
                TextField(
                  controller: _password,
                  obscureText: !_showPassword,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: '密碼',
                    suffixIcon: IconButton(
                      tooltip: _showPassword ? '隱藏密碼' : '顯示密碼',
                      onPressed: () => setState(() => _showPassword = !_showPassword),
                      icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF8A8175)),
                    ),
                  ),
                ),
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
  const DeskPage({super.key, required this.talk, required this.session, required this.initialHotelId, required this.onHotelChanged});

  final TalkController talk;
  final StaffSession session;
  final String? initialHotelId;
  final ValueChanged<String> onHotelChanged;

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
  var _loadToken = 0;

  @override
  void initState() {
    super.initState();
    final hotels = widget.session.hotels;
    final requested = widget.initialHotelId;
    if (requested != null && hotels.any((hotel) => hotel.id == requested)) {
      _load(requested);
    } else if (hotels.isNotEmpty) {
      _load(hotels.first.id);
    }
  }

  @override
  void didUpdateWidget(DeskPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final talk = widget.talk;
    if (talk.phase != CallPhase.incoming || talk.hotelId.isEmpty || talk.hotelId == _hotelId) return;
    if (!widget.session.hotels.any((hotel) => hotel.id == talk.hotelId)) return;
    _load(talk.hotelId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onHotelChanged(talk.hotelId);
    });
  }

  Hotel? get _hotel {
    for (final hotel in widget.session.hotels) {
      if (hotel.id == _hotelId) return hotel;
    }
    return null;
  }

  Future<void> _load(String hotelId, {bool remember = false}) async {
    final token = ++_loadToken;
    if (remember) widget.onHotelChanged(hotelId);
    setState(() {
      _hotelId = hotelId;
      _machines = null;
      _links = const {};
      _linksReady = false;
      _error = '';
    });
    try {
      final hotels = widget.session.hotels;
      final start = hotels.indexWhere((hotel) => hotel.id == hotelId);
      final order = <String>[hotelId];
      if (!remember && start >= 0) {
        for (var step = 1; step < hotels.length; step++) {
          order.add(hotels[(start + step) % hotels.length].id);
        }
      }
      for (var index = 0; index < order.length; index++) {
        final id = order[index];
        final listed = await widget.talk.api.machines(id);
        if (!mounted || token != _loadToken) return;
        final status = listed.isEmpty
            ? (links: const <String, bool>{}, registered: const <String>{})
            : await widget.talk.api.machineLinks(id, listed.map((item) => item.code).toList());
        if (!mounted || token != _loadToken) return;
        final machines = listed.where((item) => status.registered.contains(item.code)).toList();
        if (machines.isEmpty && index < order.length - 1) continue;
        if (machines.isNotEmpty) widget.onHotelChanged(id);
        setState(() {
          _hotelId = id;
          _machines = machines;
          _links = status.links;
          _linksReady = true;
        });
        return;
      }
    } on ApiException catch (error) {
      if (error.status == 401) {
        await clearSession();
        widget.talk.clearLocalSession();
        return;
      }
      if (!mounted || token != _loadToken) return;
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
                        onSelected: (_) => _load(item.id, remember: true),
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
    if (machines.isEmpty) return const Center(child: Text('這間旅店沒有已註冊通話的機台', style: TextStyle(color: _paper, fontSize: 20)));
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
    final incoming = callLabel == '來電';
    final idle = widget.talk.phase == CallPhase.idle || widget.talk.phase == CallPhase.ended;
    final ready = _linksReady && online == true && idle && callLabel == null;
    final hotel = _hotel;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: incoming ? const Color(0xFFF7F4EE) : _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: incoming ? const Color(0xFFE4DCCB) : (callLabel == null ? _gold.withValues(alpha: 0.45) : _gold), width: callLabel == null ? 1 : 2),
      ),
      child: Padding(
        padding: EdgeInsets.all(large ? 20 : 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(machine.name.isEmpty ? machine.code : machine.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: incoming ? const Color(0xFF1C1914) : _paper, fontSize: large ? 28 : 18, fontWeight: FontWeight.w600)),
            if (machine.name.isNotEmpty) Text(machine.code, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: incoming ? const Color(0xFF5C574E) : _muted, fontSize: large ? 14 : 12)),
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
    final incoming = callLabel == '來電';
    final color = incoming ? const Color(0xFF1C1914) : (callLabel != null || online == true ? _gold : _muted);
    final text = callLabel ?? (online == null ? '確認中' : (online ? '線上' : '未連線'));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: incoming ? const Color(0xFFEFEAE0) : _ink, borderRadius: BorderRadius.circular(20)),
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
  var _more = false;
  var _loadingMore = false;
  var _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more) {
      if (_loadingMore || !_more) return;
      setState(() => _loadingMore = true);
    } else {
      setState(() => _error = '');
    }
    try {
      final before = more && _rows != null && _rows!.isNotEmpty ? _rows!.last.createdAt : null;
      final page = await widget.talk.api.calls(before: before);
      if (!mounted) return;
      final seen = <String>{};
      final rows = <CallLog>[];
      final prior = more ? (_rows ?? const <CallLog>[]) : const <CallLog>[];
      for (final item in [...prior, ...page.calls]) {
        if (item.merchantNo.isNotEmpty && !seen.add(item.merchantNo)) continue;
        rows.add(item);
      }
      setState(() {
        _rows = rows;
        _more = page.more;
        _loadingMore = false;
      });
      if (!more) await widget.talk.markHistorySeen(rows);
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
          _loadingMore = false;
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
                  itemCount: rows.length + (_more ? 1 : 0),
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    if (index >= rows.length) {
                      return TextButton(onPressed: _loadingMore ? null : () => _load(more: true), child: Text(_loadingMore ? '載入中…' : '載入更早的紀錄'));
                    }
                    return _row(rows[index]);
                  },
                ),
    );
  }

  Widget _row(CallLog item) {
    final length = _length(item.duration);
    final when = _when(item.createdAt);
    final missed = item.status == 'rejected';
    final outgoing = item.direction != 'in';
    final person = _person(item);
    final from = outgoing ? person : item.label;
    final to = outgoing ? item.label : person;
    final turnedBack = item.unanswered;
    final hotel = widget.talk.hotelName(item.hotelId);
    const nameStyle = TextStyle(color: Color(0xFFF4EDE2), fontSize: 18);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF2A2622),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFC6A15B).withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hotel.isNotEmpty) ...[
                    Text(hotel, style: const TextStyle(color: Color(0xFFC6A15B), fontSize: 14)),
                    const SizedBox(height: 6),
                  ],
                  Row(
                    children: [
                      if (from.isNotEmpty) Flexible(child: Text(from, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle)),
                      if (from.isNotEmpty && to.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.arrow_forward, size: 20, color: missed ? const Color(0xFF8C3A3A) : const Color(0xFFC6A15B), semanticLabel: missed ? '拒接' : (outgoing ? '撥出' : '撥入')),
                        const SizedBox(width: 8),
                      ],
                      if (turnedBack) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.call_missed_outgoing, size: 20, color: Color(0xFF8C3A3A), semanticLabel: '未接'),
                      ],
                      if (to.isNotEmpty) Flexible(child: Text(to, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle)),
                    ],
                  ),
                  if (length.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(length, style: const TextStyle(color: Color(0xFF8A8175), fontSize: 15)),
                  ],
                  if (when.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(when, style: const TextStyle(color: Color(0xFF8A8175), fontSize: 15)),
                  ],
                ],
              ),
            ),
            IconButton(tooltip: '回撥', onPressed: () => _confirmCall(item), icon: const Icon(Icons.call, color: Color(0xFFC6A15B))),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCall(CallLog item) async {
    final hotel = widget.talk.hotelName(item.hotelId);
    final who = hotel.isEmpty ? item.label : '$hotel　${item.label}';
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('回撥'),
        content: Text('要撥給 $who 嗎？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('撥打')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _callBack(item);
  }

  Future<void> _callBack(CallLog item) async {
    final error = await widget.talk.callBack(item);
    if (!mounted || error == null || error.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  String _person(CallLog item) {
    final name = item.direction == 'in' ? (item.status == 'rejected' ? item.endedName : item.answeredName) : item.callerName;
    final text = name.trim();
    if (text.isEmpty || text == '機台' || text == item.machineName || text == item.machineCode) return '';
    return text;
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

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.talk, required this.session});

  final TalkController talk;
  final StaffSession session;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  var _push = '確認中';

  @override
  void initState() {
    super.initState();
    _loadPush();
  }

  Future<void> _loadPush() async {
    final text = await widget.talk.pushStatusLabel();
    if (mounted) setState(() => _push = text);
  }

  Future<void> _logout() async {
    final live = widget.talk.phase != CallPhase.idle && widget.talk.phase != CallPhase.ended;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('登出'),
        content: Text(live ? '登出後這支手機就不再接聽，目前的通話會先結束。' : '登出後這支手機就不再接聽。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('登出')),
        ],
      ),
    );
    if (yes != true) return;
    await widget.talk.logout();
  }

  @override
  Widget build(BuildContext context) {
    final talk = widget.talk;
    return AnimatedBuilder(
      animation: talk,
      builder: (context, _) {
        final blocked = _push != '確認中' && _push != '這支手機可以接收來電';
        return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('帳號', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: const Color(0xFF8A8175))),
          const SizedBox(height: 6),
          Text(widget.session.account, style: const TextStyle(color: Color(0xFFF4EDE2), fontSize: 22)),
          const SizedBox(height: 28),
          Text('來電', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: const Color(0xFF8A8175))),
          const SizedBox(height: 6),
          Text(_push, style: const TextStyle(color: Color(0xFFF4EDE2), fontSize: 18)),
          const SizedBox(height: 12),
          if (blocked)
            OutlinedButton(
              onPressed: () async {
                await talk.registerPush();
                await _loadPush();
                if (!mounted || _push == '這支手機可以接收來電') return;
                await talk.openNotificationSettings();
              },
              child: const Text('檢查並開啟通知'),
            ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: talk.previewing || talk.phase == CallPhase.incoming || talk.phase == CallPhase.dialing || talk.phase == CallPhase.connecting || talk.phase == CallPhase.inCall ? null : talk.previewRing,
            child: Text(talk.previewing ? '試鈴中…' : '試鈴'),
          ),
          const SizedBox(height: 28),
          FilledButton(onPressed: _logout, child: const Text('登出')),
        ],
      ),
    );
      },
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
        final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
        return PopScope(
          canPop: phase == CallPhase.idle || phase == CallPhase.ended,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (talk.fullscreen) {
              talk.toggleFullscreen();
            } else if (phase == CallPhase.incoming) {
              talk.decline();
            } else {
              talk.hangup();
            }
          },
          child: Scaffold(
          backgroundColor: phase == CallPhase.incoming ? const Color(0xFFF7F4EE) : Colors.black,
          appBar: landscape || talk.fullscreen
              ? null
              : AppBar(
                  backgroundColor: phase == CallPhase.incoming ? const Color(0xFFF7F4EE) : Colors.black,
                  foregroundColor: phase == CallPhase.incoming ? const Color(0xFF1C1914) : Colors.white,
                  title: _callTitle(),
                ),
          body: landscape || talk.fullscreen ? _fullBody(context, phase, landscape: landscape) : Column(
            children: [
              Expanded(child: _body(context, phase)),
              if (talk.hasWaiting) _waitingStrip(),
              if (talk.media.recovering)
                const Padding(padding: EdgeInsets.all(12), child: Text('正在重新連線', style: TextStyle(color: Colors.white))),
              if (talk.message.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(talk.message, style: TextStyle(color: phase == CallPhase.incoming ? const Color(0xFF5C574E) : Colors.white))),
              SafeArea(child: _actions(phase)),
            ],
          ),
          ),
        );
      },
    );
  }

  Widget _callTitle() {
    final hotel = talk.hotelName(talk.hotelId);
    final peer = talk.peerLabel.isEmpty ? '通話' : talk.peerLabel;
    if (hotel.isEmpty) return Text(peer);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(hotel, style: const TextStyle(fontSize: 13)),
        Text(peer, style: const TextStyle(fontSize: 18)),
      ],
    );
  }

  Widget _fullBody(BuildContext context, CallPhase phase, {required bool landscape}) {
    final video = Column(
      children: [
        Expanded(child: _body(context, phase)),
        if (talk.hasWaiting) _waitingStrip(),
        if (talk.media.recovering) const Padding(padding: EdgeInsets.all(12), child: Text('正在重新連線', style: TextStyle(color: Colors.white))),
        if (talk.message.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(talk.message, style: TextStyle(color: phase == CallPhase.incoming ? const Color(0xFF5C574E) : Colors.white))),
      ],
    );
    if (!landscape) {
      return Column(
        children: [
          Expanded(child: video),
          SafeArea(top: false, child: _actions(phase)),
        ],
      );
    }
    return SafeArea(
      child: Row(
        children: [
          Expanded(child: video),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: _actionButtons(phase),
            ),
          ),
        ],
      ),
    );
  }

  Widget _remoteMark(Rect frame, Size size) {
    const text = Text('遠端協助中', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 11, height: 1));
    if (size.width > size.height) {
      return Positioned(
        left: 0,
        width: frame.left,
        top: frame.top,
        height: frame.height,
        child: const Align(
          alignment: Alignment.centerRight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFFE23B3B),
              borderRadius: BorderRadius.horizontal(left: Radius.circular(6)),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(4, 6, 3, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('遠', style: TextStyle(color: Colors.white, fontSize: 11, height: 1.15)),
                  Text('端', style: TextStyle(color: Colors.white, fontSize: 11, height: 1.15)),
                  Text('協', style: TextStyle(color: Colors.white, fontSize: 11, height: 1.15)),
                  Text('助', style: TextStyle(color: Colors.white, fontSize: 11, height: 1.15)),
                  Text('中', style: TextStyle(color: Colors.white, fontSize: 11, height: 1.15)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    const bar = 14.0;
    final top = frame.top - bar < 0 ? 0.0 : frame.top - bar;
    return Positioned(
      left: frame.left,
      top: top,
      width: frame.width,
      height: bar,
      child: const ColoredBox(
        color: Color(0xFFE23B3B),
        child: Center(child: text),
      ),
    );
  }

  Widget _waitingStrip() {
    return Material(
      color: const Color(0xFFF7F4EE),
      shape: const Border(top: BorderSide(color: Color(0xFFE4DCCB))),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final item in talk.waiting)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('另一通來電', style: TextStyle(color: Color(0xFF1C1914), fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(_place(item.hotelId, item.label), style: const TextStyle(color: Color(0xFF5C574E), fontSize: 16)),
                    const SizedBox(height: 4),
                    const Text('要接這通，請先掛斷目前的通話', style: TextStyle(color: Color(0xFF5C574E), fontSize: 14)),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton(
                        onPressed: () => talk.rejectWaiting(item),
                        style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF1C1914), backgroundColor: const Color(0xFFEFEAE0), side: const BorderSide(color: Color(0xFFCFC6B6))),
                        child: const Text('拒接'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _place(String hotelId, String machine) {
    final hotel = talk.hotelName(hotelId);
    if (hotel.isEmpty) return machine;
    return '$hotel　$machine';
  }

  Widget _body(BuildContext context, CallPhase phase) {
    if (phase == CallPhase.inCall || phase == CallPhase.connecting) {
      final media = talk.media;
      final screenReady = media.screenFrame && media.hasScreen;
      final cameraReady = media.cameraFrame && media.hasCamera;
      if (!screenReady && !cameraReady) {
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFFC6A15B)),
              ),
              SizedBox(height: 12),
              Text('畫面準備中', style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
        );
      }
      final both = screenReady && cameraReady;
      final largeIsScreen = screenReady && (!cameraReady || talk.screenLarge);
      final screen = screenReady ? _screenView(mark: largeIsScreen && talk.remoteControl, control: largeIsScreen) : const SizedBox.shrink();
      final cameraFit = !largeIsScreen && MediaQuery.orientationOf(context) == Orientation.landscape
          ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
          : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover;
      final camera = cameraReady
          ? ClipRect(
              child: RotatedBox(
                quarterTurns: 1,
                child: RTCVideoView(media.cameraView, objectFit: cameraFit),
              ),
            )
          : const SizedBox.shrink();
      final large = largeIsScreen ? screen : camera;
      final small = largeIsScreen ? camera : screen;
      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: large),
            if (both && talk.showSmall)
              Positioned(
                right: 16,
                top: 16,
                width: 120,
                height: 168,
                child: GestureDetector(
                  onTap: talk.swapVideo,
                  child: DecoratedBox(
                    decoration: BoxDecoration(border: Border.all(color: Colors.white54)),
                    child: small,
                  ),
                ),
              ),
          ],
        ),
      );
    }
    final text = switch (phase) {
      CallPhase.dialing => '撥號中…',
      CallPhase.incoming => '機台來電',
      CallPhase.ended => talk.message.isEmpty ? '通話結束' : talk.message,
      _ => '準備通話',
    };
    final incoming = phase == CallPhase.incoming;
    return Center(child: Text(text, style: TextStyle(color: incoming ? const Color(0xFF1C1914) : Colors.white, fontSize: incoming ? 36 : 28, fontWeight: incoming ? FontWeight.w700 : FontWeight.w400)));
  }

  Widget _screenView({required bool mark, bool control = true}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        const border = 3.0;
        const markBar = 14.0;
        final edge = talk.remoteControl ? border : 0.0;
        final portraitMark = mark && size.height >= size.width;
        var topInset = 0.0;
        if (portraitMark) {
          final trialWidth = size.width > edge * 2 ? size.width - edge * 2 : 0.0;
          final trialHeight = size.height > edge * 2 ? size.height - edge * 2 : 0.0;
          final trial = _videoRect(Size(trialWidth, trialHeight)).shift(Offset(edge, edge));
          final trialTop = talk.remoteControl ? trial.top - border : trial.top;
          if (trialTop < markBar) topInset = markBar;
        }
        final content = Size(
          size.width > edge * 2 ? size.width - edge * 2 : 0,
          size.height > edge * 2 + topInset ? size.height - edge * 2 - topInset : 0,
        );
        final picture = _videoRect(content).shift(Offset(edge, edge + topInset));
        final outer = talk.remoteControl ? picture.inflate(border) : picture;
        return GestureDetector(
          onTapUp: control ? (details) => _tap(details.localPosition, picture) : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fromRect(
                rect: Rect.fromLTWH(edge, edge + topInset, content.width, content.height),
                child: RTCVideoView(talk.media.screenView, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
              ),
              if (talk.remoteControl && picture.width > 0 && picture.height > 0)
                Positioned.fromRect(
                  rect: outer,
                  child: const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(border: Border.fromBorderSide(BorderSide(color: Color(0xFFE23B3B), width: border))),
                    ),
                  ),
                ),
              if (mark && picture.width > 0 && picture.height > 0) _remoteMark(outer, size),
            ],
          ),
        );
      },
    );
  }

  Rect _videoRect(Size size) {
    var width = talk.media.videoWidth.toDouble();
    var height = talk.media.videoHeight.toDouble();
    final rotation = talk.media.videoRotation;
    if (rotation == 90 || rotation == 270) {
      final swap = width;
      width = height;
      height = swap;
    }
    if (width <= 0 || height <= 0 || size.width <= 0 || size.height <= 0) return Offset.zero & size;
    final scale = (size.width / width) < (size.height / height) ? size.width / width : size.height / height;
    final drawnWidth = width * scale;
    final drawnHeight = height * scale;
    return Rect.fromLTWH((size.width - drawnWidth) / 2, (size.height - drawnHeight) / 2, drawnWidth, drawnHeight);
  }

  void _tap(Offset local, Rect frame) {
    if (frame.width <= 0 || frame.height <= 0) return;
    final x = (local.dx - frame.left) / frame.width;
    final y = (local.dy - frame.top) / frame.height;
    if (x < 0 || y < 0 || x > 1 || y > 1) return;
    talk.tapVideo(x, y);
  }

  Widget _actions(CallPhase phase) {
    if (phase == CallPhase.incoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _roundAction(icon: Icons.call_end, tip: '拒接', onPressed: talk.decline, background: const Color(0xFF8C3A3A)),
          _roundAction(icon: Icons.call, tip: '接聽', onPressed: talk.accept, background: const Color(0xFFC9974A), foreground: const Color(0xFF2A1C0C)),
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
        children: _actionButtons(phase),
      ),
    );
  }

  List<Widget> _actionButtons(CallPhase phase) {
    final live = phase == CallPhase.inCall;
    final picture = talk.media.screenFrame || talk.media.cameraFrame;
    final side = <Widget>[
      _roundAction(icon: talk.muted ? Icons.mic_off : Icons.mic, tip: talk.muted ? '取消靜音' : '靜音', onPressed: live ? talk.toggleMute : null, background: talk.muted ? const Color(0xFFC6A15B) : const Color(0xFF2A2622), foreground: talk.muted ? const Color(0xFF1C1915) : Colors.white),
      _roundAction(icon: talk.speaker ? Icons.volume_up : Icons.phone_in_talk, tip: talk.speaker ? '關閉擴音' : '開啟擴音', onPressed: live ? talk.toggleSpeaker : null, background: talk.speaker ? const Color(0xFFC6A15B) : const Color(0xFF2A2622), foreground: talk.speaker ? const Color(0xFF1C1915) : Colors.white),
      if (picture) ...[
        _roundAction(icon: Icons.touch_app, tip: talk.remoteControl ? '關閉遠端操作' : '開啟遠端操作', onPressed: live ? talk.toggleRemote : null, background: talk.remoteControl ? const Color(0xFFC6A15B) : const Color(0xFF2A2622), foreground: talk.remoteControl ? const Color(0xFF1C1915) : Colors.white),
        if (talk.media.hasScreen || talk.media.hasCamera) _roundAction(icon: talk.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, tip: talk.fullscreen ? '離開全螢幕' : '全螢幕', onPressed: live ? talk.toggleFullscreen : null),
        if (talk.media.hasScreen && talk.media.hasCamera)
          _roundAction(icon: talk.showSmall ? Icons.picture_in_picture_alt : Icons.picture_in_picture, tip: talk.showSmall ? '隱藏小畫面' : '顯示小畫面', onPressed: talk.toggleSmall),
      ],
    ];
    final middle = side.length ~/ 2;
    return [
      ...side.sublist(0, middle),
      _roundAction(icon: Icons.call_end, tip: '掛斷', onPressed: talk.hangup, background: const Color(0xFF8C3A3A)),
      ...side.sublist(middle),
    ];
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
