import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Constants ─────────────────────────────────────────────────────────────────
const kServiceUUID        = "12345678-1234-1234-1234-123456789abc";
const kCharacteristicUUID = "87654321-4321-4321-4321-cba987654321";
const kDeviceName         = "WandererCover";
const kPrefDeviceId       = 'ble_device_id';

class LightConfig {
  final int index;
  final String name, brightness, heater;
  final Color color;
  const LightConfig(this.index, this.name, this.brightness, this.heater, this.color);
}

const kConfigs = [
  LightConfig(0, "Spento",   "0",   "—",     Color(0xFF444455)),
  LightConfig(1, "Config 1", "55",  "Basso", Color(0xFF4A90D9)),
  LightConfig(2, "Config 2", "130", "Medio", Color(0xFFFFB84D)),
  LightConfig(3, "Config 3", "255", "Alto",  Color(0xFFFF6B6B)),
];

void main() => runApp(const WandererApp());

class WandererApp extends StatelessWidget {
  const WandererApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'WandererCover',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF7B68EE), secondary: Color(0xFFFFD700), surface: Color(0xFF0D0D1A)),
      scaffoldBackgroundColor: const Color(0xFF0D0D1A),
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// BleManager con riconnessione automatica
// ══════════════════════════════════════════════════════════════════════════════
class BleManager {
  final connected        = ValueNotifier<bool>(false);
  final autoReconnecting = ValueNotifier<bool>(false);
  final status           = ValueNotifier<String>("Disconnesso");
  final busy             = ValueNotifier<bool>(false);
  final coverOpen        = ValueNotifier<bool>(false);
  final configIndex      = ValueNotifier<int>(0);
  final phase            = ValueNotifier<String>("");   // "arming" | "stepping" | ""
  final stepInfo         = ValueNotifier<String>("");   // es. "2/3"

  BluetoothDevice?         _device;
  BluetoothCharacteristic? _char;
  StreamSubscription?      _notifSub, _scanSub, _connSub;
  Timer?                   _reconnectTimer;
  String?                  _knownId;
  bool                     _userDisconnected = false;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _knownId = p.getString(kPrefDeviceId);
    if (_knownId != null) {
      status.value = "Connessione automatica...";
      startAutoScan();
    }
  }

  Future<void> _perms() async {
    await [Permission.bluetoothScan, Permission.bluetoothConnect,
           Permission.locationWhenInUse].request();
  }

  void startAutoScan() async {
    if (connected.value || _userDisconnected) return;
    await _perms();
    autoReconnecting.value = true;
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName == kDeviceName ||
            (_knownId != null && r.device.remoteId.str == _knownId)) {
          FlutterBluePlus.stopScan();
          _connect(r.device, auto: true);
          break;
        }
      }
    });
    Future.delayed(const Duration(seconds: 13), () {
      if (!connected.value && !_userDisconnected) {
        autoReconnecting.value = false;
        _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_userDisconnected || _knownId == null) return;
    _reconnectTimer = Timer(const Duration(seconds: 10), startAutoScan);
  }

  Future<void> manualScan() async {
    _userDisconnected = false;
    await _perms();
    status.value = "Ricerca in corso...";
    autoReconnecting.value = true;
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName == kDeviceName) {
          FlutterBluePlus.stopScan();
          _connect(r.device, auto: false);
          break;
        }
      }
    });
    Future.delayed(const Duration(seconds: 11), () {
      if (!connected.value) {
        autoReconnecting.value = false;
        status.value = "Dispositivo non trovato";
      }
    });
  }

  Future<void> _connect(BluetoothDevice dev, {required bool auto}) async {
    autoReconnecting.value = false;
    status.value = auto ? "Riconnessione..." : "Connessione...";
    try {
      await dev.connect(timeout: const Duration(seconds: 10));
      _device = dev;
      final p = await SharedPreferences.getInstance();
      await p.setString(kPrefDeviceId, dev.remoteId.str);
      _knownId = dev.remoteId.str;

      for (final s in await dev.discoverServices()) {
        if (s.uuid.toString().toLowerCase() == kServiceUUID) {
          for (final c in s.characteristics) {
            if (c.uuid.toString().toLowerCase() == kCharacteristicUUID) {
              _char = c;
              await c.setNotifyValue(true);
              _notifSub?.cancel();
              _notifSub = c.onValueReceived.listen(_onNotif);
            }
          }
        }
      }
      _connSub?.cancel();
      _connSub = dev.connectionState.listen((st) {
        if (st == BluetoothConnectionState.disconnected) {
          connected.value = false; busy.value = false;
          _char = null; _device = null;
          if (!_userDisconnected) { status.value = "Persa — riprovo..."; _scheduleReconnect(); }
          else status.value = "Disconnesso";
        }
      });
      connected.value = true;
      status.value = auto ? "Riconnesso ✓" : "Connesso ✓";
    } catch (e) {
      status.value = "Errore: $e";
      if (!_userDisconnected) _scheduleReconnect();
    }
  }

  void _onNotif(List<int> val) {
    final msg = utf8.decode(val);
    if (msg.startsWith("BUSY:")) busy.value = true;
    else if (msg == "READY") { busy.value = false; phase.value = ""; stepInfo.value = ""; }
    else if (msg == "ARMING") { phase.value = "arming"; }
    else if (msg.startsWith("STEPPING:")) { phase.value = "stepping"; stepInfo.value = msg.substring(9); }
    else if (msg == "COVER:open") coverOpen.value = true;
    else if (msg == "COVER:closed") coverOpen.value = false;
    else if (msg.startsWith("CONFIG_INDEX:")) configIndex.value = int.tryParse(msg.substring(13)) ?? 0;
    else if (msg.startsWith("ERROR:")) { busy.value = false; phase.value = ""; status.value = "Errore: ${msg.substring(6)}"; }
  }

  Future<bool> send(String cmd) async {
    if (!connected.value || _char == null) return false;
    // I comandi non-taglio (timer/reset/gap) passano anche se busy
    final immediate = cmd.startsWith("TIMER_") || cmd == "RESET_STATE" || cmd.startsWith("SET_GAP:");
    if (busy.value && !immediate) return false;
    try {
      await _char!.write(utf8.encode(cmd), withoutResponse: false);
      return true;
    } catch (e) { status.value = "Errore invio: $e"; return false; }
  }

  void disconnect() {
    _userDisconnected = true;
    _reconnectTimer?.cancel(); _scanSub?.cancel(); _notifSub?.cancel(); _connSub?.cancel();
    _device?.disconnect();
    connected.value = false; autoReconnecting.value = false; busy.value = false;
    status.value = "Disconnesso"; _char = null; _device = null;
  }

  Future<void> forget() async {
    disconnect();
    _knownId = null;
    final p = await SharedPreferences.getInstance();
    await p.remove(kPrefDeviceId);
  }

  void dispose() {
    _reconnectTimer?.cancel(); _scanSub?.cancel(); _notifSub?.cancel(); _connSub?.cancel();
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// HomePage
// ══════════════════════════════════════════════════════════════════════════════
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _tab = 0;
  final _ble = BleManager();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ble.init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed && !_ble.connected.value) _ble.startAutoScan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ble.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      ControlTab(ble: _ble),
      TimerTab(ble: _ble),
    ];
    return Scaffold(
      body: tabs[_tab],
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF0D0D1A),
        indicatorColor: const Color(0xFF7B68EE).withOpacity(0.25),
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.tune), label: "Controllo"),
          NavigationDestination(icon: Icon(Icons.timer_outlined), label: "Sessione"),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TAB 1 — Controllo
// ══════════════════════════════════════════════════════════════════════════════
class ControlTab extends StatelessWidget {
  final BleManager ble;
  const ControlTab({super.key, required this.ble});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: AnimatedBuilder(
        animation: ble.connected,
        builder: (_, __) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header(context),
          const SizedBox(height: 16),
          _statusCard(),
          const SizedBox(height: 20),
          if (ble.connected.value) ...[
            _coverCard(),
            const SizedBox(height: 20),
            _configSection(),
            const SizedBox(height: 20),
            _resetButton(),
            const SizedBox(height: 12),
            Center(child: TextButton.icon(
              onPressed: ble.disconnect,
              icon: const Icon(Icons.bluetooth_disabled, size: 16),
              label: const Text("Disconnetti"),
              style: TextButton.styleFrom(foregroundColor: Colors.white24))),
          ] else
            _connectSection(),
        ]),
      ),
    ),
  );

  Widget _header(BuildContext context) => Row(children: [
    const Text("🔭", style: TextStyle(fontSize: 28)),
    const SizedBox(width: 10),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text("WandererCover",
        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      AnimatedBuilder(
        animation: Listenable.merge([ble.connected, ble.autoReconnecting]),
        builder: (_, __) {
          String s = ble.autoReconnecting.value ? "🔄 Ricerca automatica..."
              : ble.connected.value ? "📶 Bluetooth" : "Non connesso";
          return Text(s, style: const TextStyle(color: Colors.white38, fontSize: 12));
        }),
    ])),
    if (ble.connected.value)
      IconButton(
        onPressed: () async {
          final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A2E),
            title: const Text("Dimentica dispositivo", style: TextStyle(color: Colors.white)),
            content: const Text("La prossima volta dovrai cercarlo manualmente.",
              style: TextStyle(color: Colors.white54)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Annulla")),
              TextButton(onPressed: () => Navigator.pop(context, true),
                child: const Text("Dimentica", style: TextStyle(color: Color(0xFFFF6B6B)))),
            ],
          ));
          if (ok == true) await ble.forget();
        },
        icon: const Icon(Icons.link_off, size: 20, color: Colors.white24)),
  ]);

  Widget _statusCard() => AnimatedBuilder(
    animation: Listenable.merge([ble.status, ble.busy, ble.autoReconnecting, ble.connected, ble.phase, ble.stepInfo]),
    builder: (_, __) {
      final isBusy = ble.busy.value;
      final isAuto = ble.autoReconnecting.value;
      final conn = ble.connected.value;
      final color = conn ? (isBusy ? const Color(0xFFFFD700) : const Color(0xFF4CAF50))
          : isAuto ? const Color(0xFF7B68EE) : Colors.white38;
      // Messaggio dinamico in base alla fase
      String msg = ble.status.value;
      if (ble.phase.value == "arming") msg = "⏳ Attendo standby (13-15s)...";
      else if (ble.phase.value == "stepping") msg = "🔄 Cambio config — step ${ble.stepInfo.value}";
      return Container(
        width: double.infinity, padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withOpacity(0.35))),
        child: Row(children: [
          if (isAuto) const SizedBox(width: 10, height: 10,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF7B68EE)))
          else Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: color,
            boxShadow: conn ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 6)] : [])),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, style: TextStyle(color: color, fontSize: 14))),
          if (isBusy) const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFD700))),
        ]),
      );
    },
  );

  Widget _coverCard() => AnimatedBuilder(
    animation: Listenable.merge([ble.coverOpen, ble.busy]),
    builder: (_, __) {
      final open = ble.coverOpen.value;
      return GestureDetector(
        onTap: ble.busy.value ? null : () => ble.send("COVER_TOGGLE"),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: double.infinity, padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: open ? const Color(0xFF7B68EE).withOpacity(0.12) : const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: open ? const Color(0xFF7B68EE) : Colors.white12, width: open ? 2 : 1)),
          child: Column(children: [
            Icon(open ? Icons.flip_to_front : Icons.flip_to_back,
              size: 48, color: open ? const Color(0xFF7B68EE) : Colors.white38),
            const SizedBox(height: 12),
            Text(open ? "COVER APERTO" : "COVER CHIUSO",
              style: TextStyle(color: open ? const Color(0xFF7B68EE) : Colors.white70,
                fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text("Tocca per ${open ? 'chiudere' : 'aprire'} (taglio 2.3s)",
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ]),
        ),
      );
    },
  );

  Widget _configSection() => AnimatedBuilder(
    animation: Listenable.merge([ble.configIndex, ble.busy]),
    builder: (_, __) {
      final cur = ble.configIndex.value;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("CONFIGURAZIONE LUCE", style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.2)),
        const SizedBox(height: 12),
        ...kConfigs.map((c) {
          final isCur = c.index == cur;
          final enabled = !ble.busy.value && !isCur;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GestureDetector(
              onTap: enabled ? () => ble.send("CONFIG_SET:${c.index}") : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                decoration: BoxDecoration(
                  color: isCur ? c.color.withOpacity(0.15) : const Color(0xFF1A1A2E),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: isCur ? c.color : Colors.white12, width: isCur ? 2 : 1)),
                child: Row(children: [
                  Container(width: 44, height: 44,
                    decoration: BoxDecoration(color: c.color.withOpacity(0.2), shape: BoxShape.circle),
                    child: Icon(c.index == 0 ? Icons.power_settings_new : Icons.wb_sunny, color: c.color, size: 22)),
                  const SizedBox(width: 16),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.name, style: TextStyle(color: isCur ? c.color : Colors.white,
                      fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(c.index == 0 ? "Luce spenta" : "Luminosità ${c.brightness} · Heater ${c.heater}",
                      style: const TextStyle(color: Colors.white38, fontSize: 12)),
                  ])),
                  if (isCur) Icon(Icons.check_circle, color: c.color, size: 22)
                  else if (enabled) const Icon(Icons.chevron_right, color: Colors.white24),
                ]),
              ),
            ),
          );
        }),
        const SizedBox(height: 4),
        // Pulsante Spegni — visibile solo se la luce è accesa
        if (cur > 0) ...[
          SizedBox(width: double.infinity, height: 46,
            child: ElevatedButton.icon(
              onPressed: ble.busy.value ? null : () => ble.send("CONFIG_SET:0"),
              icon: const Icon(Icons.power_settings_new, size: 18),
              label: const Text("Spegni luce"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF442233),
                foregroundColor: const Color(0xFFFF6B6B),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            )),
          const SizedBox(height: 12),
        ],
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(10)),
          child: const Text(
            "💡 Le config sono i preset 1-2-3 salvati in WandererEmpire. Ogni cambio è un taglio da 1.3s. 'Spegni' cicla fino a tornare a luce spenta.",
            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5)),
        ),
      ]);
    },
  );

  Widget _resetButton() => AnimatedBuilder(
    animation: ble.busy,
    builder: (_, __) => OutlinedButton.icon(
      onPressed: ble.busy.value ? null : () => ble.send("RESET_STATE"),
      icon: const Icon(Icons.restart_alt, size: 18),
      label: const Text("Reset stato (cover chiuso, luce spenta)"),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white54, side: const BorderSide(color: Colors.white24),
        minimumSize: const Size(double.infinity, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
  );

  Widget _connectSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const SizedBox(height: 20),
    const Center(child: Text("Connetti il WandererCover via Bluetooth",
      style: TextStyle(color: Colors.white54, fontSize: 15))),
    const SizedBox(height: 24),
    AnimatedBuilder(animation: ble.autoReconnecting, builder: (_, __) {
      final auto = ble.autoReconnecting.value;
      return SizedBox(width: double.infinity, height: 52, child: ElevatedButton.icon(
        onPressed: auto ? null : ble.manualScan,
        icon: auto ? const SizedBox(width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.bluetooth_searching, size: 20),
        label: Text(auto ? "Ricerca in corso..." : "Cerca WandererCover"),
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7B68EE),
          foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))));
    }),
  ]);
}

// ══════════════════════════════════════════════════════════════════════════════
// TAB 2 — Sessione (config + timer opzionale apertura)
// ══════════════════════════════════════════════════════════════════════════════
class TimerTab extends StatefulWidget {
  final BleManager ble;
  const TimerTab({super.key, required this.ble});
  @override State<TimerTab> createState() => _TimerTabState();
}

class _TimerTabState extends State<TimerTab> {
  bool _timerEnabled = false;
  int  _durationHours = 8;
  int  _durationMins  = 0;
  int  _sessionConfig = 1;

  Timer? _ticker;
  bool _running = false;
  DateTime? _fireAt;
  Duration _left = Duration.zero;
  String _statusMsg = "";

  BleManager get ble => widget.ble;

  @override
  void dispose() { _ticker?.cancel(); super.dispose(); }

  int get _durationMs => (_durationHours * 3600 + _durationMins * 60) * 1000;

  void _start() async {
    if (!ble.connected.value) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Connetti prima il dispositivo")));
      return;
    }
    setState(() => _statusMsg = "Imposto ${kConfigs[_sessionConfig].name}...");
    await ble.send("CONFIG_SET:$_sessionConfig");

    if (_timerEnabled && _durationMs > 0) {
      await ble.send("TIMER_START:$_durationMs");
      _fireAt = DateTime.now().add(Duration(milliseconds: _durationMs));
      setState(() { _running = true; _statusMsg = ""; });
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        final diff = _fireAt!.difference(DateTime.now());
        if (diff.inSeconds <= 0) {
          _ticker?.cancel();
          setState(() { _running = false; _left = Duration.zero; _statusMsg = "✓ Cover aperto automaticamente"; });
        } else setState(() => _left = diff);
      });
    } else {
      setState(() => _statusMsg = "✓ ${kConfigs[_sessionConfig].name} attiva (nessun timer)");
    }
  }

  void _cancel() async {
    _ticker?.cancel();
    await ble.send("TIMER_CANCEL");
    setState(() { _running = false; _left = Duration.zero; _statusMsg = "Timer annullato"; });
  }

  String _fmt(Duration d) => d.inSeconds <= 0 ? "--:--:--"
      : "${d.inHours.toString().padLeft(2,'0')}:${(d.inMinutes%60).toString().padLeft(2,'0')}:${(d.inSeconds%60).toString().padLeft(2,'0')}";

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("🌙 Sessione Flat", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text("Imposta la config e (opzionale) apri il cover a fine sessione",
          style: TextStyle(color: Colors.white38, fontSize: 13)),
        const SizedBox(height: 24),
        if (!_running) ...[
          _configPicker(),
          const SizedBox(height: 24),
          _timerToggle(),
          if (_timerEnabled) ...[
            const SizedBox(height: 16),
            _durationPicker(),
          ],
          const SizedBox(height: 24),
          _startButton(),
        ] else ...[
          _runningDisplay(),
          const SizedBox(height: 20),
          _cancelButton(),
        ],
        if (_statusMsg.isNotEmpty) ...[
          const SizedBox(height: 20),
          Container(padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(12)),
            child: Text(_statusMsg, style: const TextStyle(color: Colors.white70, fontSize: 14))),
        ],
      ]),
    ),
  );

  Widget _configPicker() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text("CONFIG LUCE PER LA SESSIONE", style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.2)),
    const SizedBox(height: 12),
    Row(children: kConfigs.where((c) => c.index > 0).map((c) {
      final sel = c.index == _sessionConfig;
      return Expanded(child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () => setState(() => _sessionConfig = c.index),
          child: AnimatedContainer(duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: sel ? c.color.withOpacity(0.15) : const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sel ? c.color : Colors.white12, width: sel ? 2 : 1)),
            child: Column(children: [
              Icon(Icons.wb_sunny, color: c.color, size: 24),
              const SizedBox(height: 6),
              Text(c.brightness, style: TextStyle(color: sel ? c.color : Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              Text("Heater ${c.heater}", style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ]),
          ),
        ),
      ));
    }).toList()),
  ]);

  Widget _timerToggle() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      const Icon(Icons.schedule, color: Color(0xFF7B68EE), size: 20),
      const SizedBox(width: 12),
      const Expanded(child: Text("Apri cover automaticamente a fine sessione",
        style: TextStyle(color: Colors.white70, fontSize: 14))),
      Switch(value: _timerEnabled, activeColor: const Color(0xFF7B68EE),
        onChanged: (v) => setState(() => _timerEnabled = v)),
    ]),
  );

  Widget _durationPicker() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text("DURATA SESSIONE", style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.2)),
    const SizedBox(height: 12),
    Row(children: [
      Expanded(child: _spinner("Ore", _durationHours, 0, 23, (v) => setState(() => _durationHours = v))),
      const SizedBox(width: 12),
      Expanded(child: _spinner("Minuti", _durationMins, 0, 59, (v) => setState(() => _durationMins = v))),
    ]),
    const SizedBox(height: 8),
    Center(child: Text("Il cover si aprirà tra ${_durationHours}h ${_durationMins}m",
      style: const TextStyle(color: Colors.white38, fontSize: 13))),
  ]);

  Widget _startButton() => SizedBox(width: double.infinity, height: 56,
    child: ElevatedButton.icon(
      onPressed: _start,
      icon: const Icon(Icons.play_arrow_rounded),
      label: Text(_timerEnabled
        ? "Avvia (apre tra ${_durationHours}h ${_durationMins}m)"
        : "Attiva ${kConfigs[_sessionConfig].name}"),
      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7B68EE),
        foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
  );

  Widget _runningDisplay() => Container(
    width: double.infinity, padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFF7B68EE).withOpacity(0.3))),
    child: Column(children: [
      const Text("APERTURA COVER TRA", style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
      const SizedBox(height: 12),
      Text(_fmt(_left), style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text("Config attiva: ${kConfigs[_sessionConfig].name}", style: const TextStyle(color: Colors.white38, fontSize: 14)),
    ]),
  );

  Widget _cancelButton() => SizedBox(width: double.infinity, height: 50,
    child: OutlinedButton.icon(onPressed: _cancel,
      icon: const Icon(Icons.stop_circle_outlined),
      label: const Text("Annulla apertura automatica"),
      style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFFF6B6B),
        side: const BorderSide(color: Color(0xFFFF6B6B), width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
  );

  Widget _spinner(String label, int val, int min, int max, ValueChanged<int> cb) => Container(
    decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(12)),
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
      IconButton(onPressed: val > min ? () => cb(val-1) : null, icon: const Icon(Icons.remove, size: 18), color: const Color(0xFF7B68EE)),
      Text("$val", style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      IconButton(onPressed: val < max ? () => cb(val+1) : null, icon: const Icon(Icons.add, size: 18), color: const Color(0xFF7B68EE)),
    ]),
  );
}
