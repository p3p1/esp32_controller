import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ── Constants ─────────────────────────────────────────────────────────────────
const kServiceUUID        = "12345678-1234-1234-1234-123456789abc";
const kCharacteristicUUID = "87654321-4321-4321-4321-cba987654321";
const kDeviceName         = "WandererCover";
const kPresets            = [0, 1, 2, 4, 8, 15, 30, 60, 120, 255];
const kPrefDeviceId       = 'ble_device_id';   // chiave SharedPreferences
const kPrefEspIp          = 'esp_ip';

void main() => runApp(const WandererApp());

class WandererApp extends StatelessWidget {
  const WandererApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'WandererCover',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: const ColorScheme.dark(
        primary:   Color(0xFF7B68EE),
        secondary: Color(0xFFFFD700),
        surface:   Color(0xFF0D0D1A),
      ),
      scaffoldBackgroundColor: const Color(0xFF0D0D1A),
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// BleManager — gestisce connessione, riconnessione automatica, notifiche
// ══════════════════════════════════════════════════════════════════════════════
class BleManager {
  // Notifiers pubblici osservati dall'UI
  final connected       = ValueNotifier<bool>(false);
  final autoReconnecting= ValueNotifier<bool>(false);  // scansione silenziosa in corso
  final bleStatus       = ValueNotifier<String>("");
  final brightnessIndex = ValueNotifier<int>(0);
  final busy            = ValueNotifier<bool>(false);

  BluetoothDevice?         _device;
  BluetoothCharacteristic? _char;
  StreamSubscription?      _notifSub;
  StreamSubscription?      _scanSub;
  StreamSubscription?      _connStateSub;
  Timer?                   _reconnectTimer;

  String? _knownDeviceId;   // remoteId salvato
  bool    _userDisconnected = false;  // true solo se l'utente ha premuto "Disconnetti"

  // ── Init ────────────────────────────────────────────────────────────────────
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _knownDeviceId = prefs.getString(kPrefDeviceId);
    if (_knownDeviceId != null) {
      bleStatus.value = "Connessione automatica...";
      _startAutoScan();
    }
  }

  // ── Scansione silenziosa in background ────────────────────────────────────
  void _startAutoScan() async {
    if (connected.value || _userDisconnected) return;

    // Richiedi permessi senza mostrare dialogo se già concessi
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final granted = statuses.values.every((s) => s.isGranted);
    if (!granted) return;

    autoReconnecting.value = true;
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final matchesName = r.device.platformName == kDeviceName;
        final matchesId   = _knownDeviceId != null &&
                            r.device.remoteId.str == _knownDeviceId;
        if (matchesName || matchesId) {
          FlutterBluePlus.stopScan();
          _connect(r.device, auto: true);
          break;
        }
      }
    });

    // Se dopo 12s non trovato, riprova tra 10s
    Future.delayed(const Duration(seconds: 13), () {
      if (!connected.value && !_userDisconnected) {
        autoReconnecting.value = false;
        _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_userDisconnected || _knownDeviceId == null) return;
    _reconnectTimer = Timer(const Duration(seconds: 10), _startAutoScan);
  }

  // ── Scansione manuale (tasto "Cerca") ────────────────────────────────────
  Future<void> manualScan() async {
    _userDisconnected = false;
    await [Permission.bluetoothScan, Permission.bluetoothConnect,
           Permission.locationWhenInUse].request();
    bleStatus.value        = "Ricerca in corso...";
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
        bleStatus.value        = "Dispositivo non trovato";
      }
    });
  }

  // ── Connessione ───────────────────────────────────────────────────────────
  Future<void> _connect(BluetoothDevice dev, {required bool auto}) async {
    autoReconnecting.value = false;
    bleStatus.value = auto ? "Riconnessione..." : "Connessione...";

    try {
      await dev.connect(timeout: const Duration(seconds: 10));
      _device = dev;

      // Salva ID per riconnessioni future
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kPrefDeviceId, dev.remoteId.str);
      _knownDeviceId = dev.remoteId.str;

      // Discover services
      final services = await dev.discoverServices();
      for (final s in services) {
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

      // Monitor stato connessione → riconnette se cade
      _connStateSub?.cancel();
      _connStateSub = dev.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          connected.value = false;
          busy.value      = false;
          _char           = null;
          _device         = null;
          if (!_userDisconnected) {
            bleStatus.value = "Connessione persa — riprovo...";
            _scheduleReconnect();
          } else {
            bleStatus.value = "";
          }
        }
      });

      connected.value = true;
      bleStatus.value = auto ? "Riconnesso ✓" : "Connesso ✓";
    } catch (e) {
      bleStatus.value        = "Errore: $e";
      autoReconnecting.value = false;
      if (!_userDisconnected) _scheduleReconnect();
    }
  }

  // ── Notifiche dall'ESP32 ──────────────────────────────────────────────────
  void _onNotif(List<int> val) {
    final msg = utf8.decode(val);
    if (msg.startsWith("BUSY:")) {
      busy.value = true;
    } else if (msg.startsWith("BRIGHTNESS_INDEX:")) {
      brightnessIndex.value = int.tryParse(msg.substring(17)) ?? 0;
    } else if (msg == "READY") {
      busy.value = false;
    } else if (msg.startsWith("ERROR:")) {
      busy.value      = false;
      bleStatus.value = "Errore: ${msg.substring(6)}";
    }
  }

  // ── Invio comando BLE ─────────────────────────────────────────────────────
  Future<bool> sendBle(String cmd) async {
    if (!connected.value || _char == null || busy.value) return false;
    try {
      await _char!.write(utf8.encode(cmd), withoutResponse: false);
      busy.value = true;
      return true;
    } catch (e) {
      bleStatus.value = "Errore invio: $e";
      return false;
    }
  }

  // ── Disconnessione manuale ────────────────────────────────────────────────
  void disconnect() {
    _userDisconnected = true;
    _reconnectTimer?.cancel();
    _scanSub?.cancel();
    _notifSub?.cancel();
    _connStateSub?.cancel();
    _device?.disconnect();
    connected.value        = false;
    autoReconnecting.value = false;
    busy.value             = false;
    bleStatus.value        = "";
    brightnessIndex.value  = 0;
    _char = null; _device = null;
  }

  // ── "Dimentica" dispositivo (rimuove ID salvato) ─────────────────────────
  Future<void> forget() async {
    disconnect();
    _knownDeviceId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kPrefDeviceId);
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _scanSub?.cancel();
    _notifSub?.cancel();
    _connStateSub?.cancel();
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

  final _ble    = BleManager();
  final status  = ValueNotifier<String>("Disconnesso");
  final busy    = ValueNotifier<bool>(false);   // unifica BLE + WiFi busy
  final transport        = ValueNotifier<String>("none");
  final brightnessIndex  = ValueNotifier<int>(0);

  String _espIp = "";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();

    // Propaga notifiers BLE verso quelli unificati
    _ble.bleStatus.addListener(() {
      if (_ble.bleStatus.value.isNotEmpty) status.value = _ble.bleStatus.value;
    });
    _ble.busy.addListener(() {
      if (transport.value == "ble") busy.value = _ble.busy.value;
    });
    _ble.connected.addListener(() {
      if (_ble.connected.value) {
        transport.value = "ble";
        status.value    = "BLE connesso ✓";
      } else if (transport.value == "ble") {
        transport.value = "none";
      }
    });
    _ble.brightnessIndex.addListener(() {
      brightnessIndex.value = _ble.brightnessIndex.value;
    });
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _espIp = prefs.getString(kPrefEspIp) ?? '');
    await _ble.init();   // avvia auto-scan se c'è un ID salvato
  }

  // Riprova riconnessione quando l'app torna in foreground
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_ble.connected.value) {
      _ble._startAutoScan();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ble.dispose();
    super.dispose();
  }

  // ── WiFi ──────────────────────────────────────────────────────────────────
  Future<bool> _wifiConnect(String ip) async {
    status.value = "Test connessione WiFi...";
    try {
      final r = await http.get(Uri.parse('http://$ip/status'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body);
        _espIp = ip;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(kPrefEspIp, ip);
        transport.value       = "wifi";
        status.value          = "WiFi connesso ✓  ($ip)";
        brightnessIndex.value = data['brightness_index'] ?? 0;
        return true;
      }
    } catch (_) {}
    status.value = "ESP32 non raggiungibile su $ip";
    return false;
  }

  // ── Invio comandi unificato ───────────────────────────────────────────────
  Future<void> sendCommand(String cmd) async {
    if (busy.value) return;

    if (transport.value == "ble") {
      await _ble.sendBle(cmd);
    } else if (transport.value == "wifi") {
      busy.value = true;
      try {
        String url;
        if (cmd.startsWith("BRIGHTNESS:")) {
          url = 'http://$_espIp/set_brightness?level=${cmd.substring(11)}';
        } else if (cmd == "OPEN_CLOSE") {
          url = 'http://$_espIp/open_close';
        } else {
          url = 'http://$_espIp/light_off';
        }
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 120));
        await _pollStatus();
        status.value = "Pronto ✓";
      } catch (e) {
        status.value = "Errore WiFi: $e";
      }
      busy.value = false;
    }
  }

  Future<void> _pollStatus() async {
    try {
      final r = await http.get(Uri.parse('http://$_espIp/status'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body);
        brightnessIndex.value = data['brightness_index'] ?? 0;
      }
    } catch (_) {}
  }

  void _disconnect() {
    if (transport.value == "ble") {
      _ble.disconnect();
    }
    transport.value = "none";
    busy.value      = false;
    status.value    = "Disconnesso";
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      ControlTab(
        connected: _ble.connected, busy: busy, status: status,
        transport: transport, autoReconnecting: _ble.autoReconnecting,
        espIp: _espIp,
        onManualScan:    _ble.manualScan,
        onWifiConnect:   _wifiConnect,
        onCommand:       sendCommand,
        onDisconnect:    _disconnect,
        onForgetDevice:  _ble.forget,
      ),
      BrightnessTab(
        connected: _ble.connected, busy: busy, status: status,
        transport: transport,
        brightnessIndex: brightnessIndex,
        onCommand: sendCommand,
      ),
      TimerTab(
        connected: _ble.connected, busy: busy,
        transport: transport,
        onCommand: sendCommand,
      ),
    ];

    return Scaffold(
      body: tabs[_tab],
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF0D0D1A),
        indicatorColor: const Color(0xFF7B68EE).withOpacity(0.25),
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.tune),              label: "Controllo"),
          NavigationDestination(icon: Icon(Icons.wb_sunny_outlined), label: "Luminosità"),
          NavigationDestination(icon: Icon(Icons.timer_outlined),    label: "Timer"),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TAB 1 — Controllo
// ══════════════════════════════════════════════════════════════════════════════
class ControlTab extends StatefulWidget {
  final ValueNotifier<bool>   connected, busy, autoReconnecting;
  final ValueNotifier<String> status, transport;
  final String espIp;
  final VoidCallback          onManualScan, onDisconnect;
  final Future<void> Function()       onForgetDevice;
  final Future<bool> Function(String) onWifiConnect;
  final Future<void> Function(String) onCommand;

  const ControlTab({super.key,
    required this.connected, required this.busy, required this.autoReconnecting,
    required this.status,    required this.transport,
    required this.espIp,     required this.onManualScan,
    required this.onWifiConnect, required this.onCommand,
    required this.onDisconnect,  required this.onForgetDevice});

  @override State<ControlTab> createState() => _ControlTabState();
}

class _ControlTabState extends State<ControlTab> {
  final _ipCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ipCtrl.text = widget.espIp;
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _header(),
        const SizedBox(height: 16),
        _statusCard(),
        const SizedBox(height: 20),
        ValueListenableBuilder(
          valueListenable: widget.connected,
          builder: (_, connected, __) => connected
              ? _commandSection()
              : _connectSection(),
        ),
      ]),
    ),
  );

  Widget _header() => Row(children: [
    const Text("🔭", style: TextStyle(fontSize: 28)),
    const SizedBox(width: 10),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text("WandererCover",
        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      ValueListenableBuilder(
        valueListenable: widget.transport,
        builder: (_, t, __) => ValueListenableBuilder(
          valueListenable: widget.autoReconnecting,
          builder: (_, auto, __) {
            String sub;
            if (auto)         sub = "🔄 Ricerca automatica...";
            else if (t == "ble")   sub = "📶 Bluetooth";
            else if (t == "wifi")  sub = "📡 WiFi";
            else                   sub = "Non connesso";
            return Text(sub, style: const TextStyle(color: Colors.white38, fontSize: 12));
          },
        ),
      ),
    ])),
    // Pulsante "Dimentica" visibile solo se BLE connesso
    ValueListenableBuilder(
      valueListenable: widget.connected,
      builder: (_, connected, __) => connected && widget.transport.value == "ble"
          ? IconButton(
              onPressed: () async {
                final ok = await showDialog<bool>(context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1A2E),
                    title: const Text("Dimentica dispositivo",
                      style: TextStyle(color: Colors.white)),
                    content: const Text(
                      "La prossima volta dovrai cercare manualmente.",
                      style: TextStyle(color: Colors.white54)),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false),
                        child: const Text("Annulla")),
                      TextButton(onPressed: () => Navigator.pop(context, true),
                        child: const Text("Dimentica",
                          style: TextStyle(color: Color(0xFFFF6B6B)))),
                    ],
                  ));
                if (ok == true) await widget.onForgetDevice();
              },
              icon: const Icon(Icons.link_off, size: 20, color: Colors.white24),
              tooltip: "Dimentica dispositivo",
            )
          : const SizedBox.shrink(),
    ),
  ]);

  Widget _statusCard() => ValueListenableBuilder(
    valueListenable: widget.status,
    builder: (_, msg, __) {
      final isConn = widget.connected.value;
      final isBusy = widget.busy.value;
      final isAuto = widget.autoReconnecting.value;
      final color  = isConn
          ? (isBusy ? const Color(0xFFFFD700) : const Color(0xFF4CAF50))
          : isAuto ? const Color(0xFF7B68EE) : Colors.white38;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Row(children: [
          // Dot animato
          if (isAuto)
            const SizedBox(width: 10, height: 10,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF7B68EE)))
          else
            Container(width: 10, height: 10,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color,
                boxShadow: isConn ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 6)] : [])),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, style: TextStyle(color: color, fontSize: 14))),
          if (isBusy)
            const SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFD700))),
        ]),
      );
    },
  );

  Widget _connectSection() => Column(children: [
    // ── BLE ─────────────────────────────────────────────────────────────────
    _sectionLabel("BLUETOOTH"),
    const SizedBox(height: 8),
    ValueListenableBuilder(
      valueListenable: widget.autoReconnecting,
      builder: (_, auto, __) => SizedBox(
        width: double.infinity, height: 50,
        child: ElevatedButton.icon(
          onPressed: auto ? null : widget.onManualScan,
          icon: auto
              ? const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.bluetooth_searching, size: 20),
          label: Text(auto ? "Ricerca in corso..." : "Cerca WandererCover via BLE"),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF7B68EE), foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        ),
      ),
    ),
    const SizedBox(height: 16),
    _divider("oppure"),
    const SizedBox(height: 16),
    // ── WiFi ────────────────────────────────────────────────────────────────
    _sectionLabel("WIFI (stessa rete ASIAir)"),
    const SizedBox(height: 8),
    Row(children: [
      Expanded(child: TextField(
        controller: _ipCtrl,
        style: const TextStyle(color: Colors.white),
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          hintText: "192.168.1.xx",
          hintStyle: const TextStyle(color: Colors.white24),
          filled: true, fillColor: const Color(0xFF1A1A2E),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.white12)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.white12)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
      )),
      const SizedBox(width: 10),
      SizedBox(height: 48, width: 100,
        child: ElevatedButton(
          onPressed: () => widget.onWifiConnect(_ipCtrl.text.trim()),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1A3A2A),
            foregroundColor: const Color(0xFF4CAF50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: const Text("Connetti"),
        )),
    ]),
  ]);

  Widget _commandSection() => ValueListenableBuilder(
    valueListenable: widget.busy,
    builder: (_, isBusy, __) => Column(children: [
      _CmdCard(icon: Icons.lens_blur, label: "Apri / Chiudi Cover",
        sub: "Taglio 3 secondi", color: const Color(0xFF7B68EE),
        enabled: !isBusy, onTap: () => widget.onCommand("OPEN_CLOSE")),
      const SizedBox(height: 14),
      _CmdCard(icon: Icons.highlight_off, label: "Spegni Luce",
        sub: "Taglio 7 secondi → luminosità 0", color: const Color(0xFFFF6B6B),
        enabled: !isBusy, onTap: () => widget.onCommand("LIGHT_OFF")),
      const Spacer(),
      Center(child: TextButton.icon(
        onPressed: widget.onDisconnect,
        icon: const Icon(Icons.bluetooth_disabled, size: 16),
        label: const Text("Disconnetti"),
        style: TextButton.styleFrom(foregroundColor: Colors.white24))),
    ]),
  );

  Widget _sectionLabel(String t) =>
      Text(t, style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.2));

  Widget _divider(String label) => Row(children: [
    const Expanded(child: Divider(color: Colors.white12)),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(label, style: const TextStyle(color: Colors.white24, fontSize: 12))),
    const Expanded(child: Divider(color: Colors.white12)),
  ]);
}

// ══════════════════════════════════════════════════════════════════════════════
// TAB 2 — Luminosità (invariata rispetto v3)
// ══════════════════════════════════════════════════════════════════════════════
class BrightnessTab extends StatelessWidget {
  final ValueNotifier<bool>   connected, busy;
  final ValueNotifier<String> status, transport;
  final ValueNotifier<int>    brightnessIndex;
  final Future<void> Function(String) onCommand;

  const BrightnessTab({super.key,
    required this.connected, required this.busy, required this.status,
    required this.transport,  required this.brightnessIndex, required this.onCommand});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("☀️  Luminosità",
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text("Seleziona un preset — l'app calcola gli step automaticamente",
          style: TextStyle(color: Colors.white38, fontSize: 13)),
        const SizedBox(height: 24),
        ValueListenableBuilder(valueListenable: brightnessIndex,
          builder: (_, idx, __) => _currentLevel(idx)),
        const SizedBox(height: 28),
        ValueListenableBuilder(valueListenable: brightnessIndex,
          builder: (_, idx, __) => ValueListenableBuilder(valueListenable: busy,
            builder: (_, isBusy, __) => ValueListenableBuilder(valueListenable: connected,
              builder: (_, isConn, __) => _presetGrid(idx, isBusy, isConn)))),
        const SizedBox(height: 16),
        _stepsInfo(),
        const Spacer(),
        ValueListenableBuilder(valueListenable: status,
          builder: (_, msg, __) => ValueListenableBuilder(valueListenable: busy,
            builder: (_, isBusy, __) => _statusBar(msg, isBusy))),
      ]),
    ),
  );

  Widget _currentLevel(int idx) {
    final value = kPresets[idx];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.3))),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text("Livello corrente", style: TextStyle(color: Colors.white54, fontSize: 13)),
          Text("$value / 255",
            style: const TextStyle(color: Color(0xFFFFD700), fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: value / 255.0,
            minHeight: 10,
            backgroundColor: Colors.white10,
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFFD700)),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          value == 0   ? "⬜ Spento" :
          value <= 4   ? "🌑 Molto bassa" :
          value <= 15  ? "🌒 Bassa" :
          value <= 60  ? "🌕 Media" :
          value <= 120 ? "⭐ Alta" : "🌟 Massima",
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ]),
    );
  }

  Widget _presetGrid(int currentIdx, bool isBusy, bool isConnected) =>
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.9),
        itemCount: kPresets.length,
        itemBuilder: (_, i) {
          final isCurrent = i == currentIdx;
          final enabled   = isConnected && !isBusy && !isCurrent;
          final steps     = i > currentIdx
              ? i - currentIdx
              : kPresets.length - currentIdx + i;
          return GestureDetector(
            onTap: enabled ? () => onCommand("BRIGHTNESS:$i") : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: isCurrent
                    ? const Color(0xFFFFD700).withOpacity(0.12)
                    : const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isCurrent
                      ? const Color(0xFFFFD700)
                      : enabled
                          ? const Color(0xFF7B68EE).withOpacity(0.4)
                          : Colors.white12,
                  width: isCurrent ? 2 : 1)),
              child: Opacity(
                opacity: enabled || isCurrent ? 1 : 0.3,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(
                    kPresets[i] == 0 ? Icons.brightness_1 : Icons.brightness_high,
                    color: isCurrent ? const Color(0xFFFFD700) : const Color(0xFF7B68EE),
                    size: kPresets[i] == 0 ? 16 : (12 + (kPresets[i] / 255 * 14)).clamp(12.0, 26.0)),
                  const SizedBox(height: 4),
                  Text("${kPresets[i]}",
                    style: TextStyle(
                      color: isCurrent ? const Color(0xFFFFD700) : Colors.white,
                      fontSize: 15,
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal)),
                  if (!isCurrent && isConnected)
                    Text("+${steps}x", style: const TextStyle(color: Colors.white24, fontSize: 9)),
                  if (isCurrent)
                    const Text("▶", style: TextStyle(color: Color(0xFFFFD700), fontSize: 9)),
                ]),
              ),
            ),
          );
        },
      );

  Widget _stepsInfo() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(10)),
    child: const Text(
      "💡 Ogni step richiede ~13 secondi (1.5s taglio + 11s standby). L'indice mostrato è sincronizzato con l'ESP32.",
      style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5)),
  );

  Widget _statusBar(String msg, bool isBusy) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      if (isBusy) ...[
        const SizedBox(width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFD700))),
        const SizedBox(width: 10),
      ],
      Expanded(child: Text(msg,
        style: TextStyle(
          color: isBusy ? const Color(0xFFFFD700) : Colors.white38,
          fontSize: 13))),
    ]),
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// TAB 3 — Timer
// ══════════════════════════════════════════════════════════════════════════════
class TimerTab extends StatefulWidget {
  final ValueNotifier<bool>   connected, busy;
  final ValueNotifier<String> transport;
  final Future<void> Function(String) onCommand;
  const TimerTab({super.key,
    required this.connected, required this.busy,
    required this.transport,  required this.onCommand});
  @override State<TimerTab> createState() => _TimerTabState();
}

class _TimerTabState extends State<TimerTab> {
  String    _mode         = "delay";
  int       _delayHours   = 8;
  int       _delayMins    = 0;
  TimeOfDay _absTime      = const TimeOfDay(hour: 3, minute: 0);
  bool      _doOpen       = true;
  int       _targetPreset = 5;
  bool      _doClose      = true;
  Timer?    _countdownTimer;
  bool      _timerActive  = false;
  DateTime? _scheduledAt;
  Duration  _remaining    = Duration.zero;
  String    _timerStatus  = "";

  @override
  void dispose() { _countdownTimer?.cancel(); super.dispose(); }

  DateTime _targetTime() {
    final now = DateTime.now();
    if (_mode == "delay") return now.add(Duration(hours: _delayHours, minutes: _delayMins));
    var t = DateTime(now.year, now.month, now.day, _absTime.hour, _absTime.minute);
    if (t.isBefore(now)) t = t.add(const Duration(days: 1));
    return t;
  }

  void _startTimer() {
    final isConn = widget.connected.value || widget.transport.value == "wifi";
    if (!isConn) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Connetti prima l'ESP32")));
      return;
    }
    _scheduledAt = _targetTime();
    setState(() { _timerActive = true; _timerStatus = ""; });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final diff = _scheduledAt!.difference(DateTime.now());
      if (diff.inSeconds <= 0) {
        _countdownTimer?.cancel();
        setState(() { _remaining = Duration.zero; _timerStatus = "⏳ Esecuzione..."; });
        await _runSequence();
        setState(() { _timerActive = false; _timerStatus = "✓ Completato"; });
      } else {
        setState(() => _remaining = diff);
      }
    });
  }

  void _cancelTimer() {
    _countdownTimer?.cancel();
    setState(() { _timerActive = false; _timerStatus = "Annullato"; _remaining = Duration.zero; });
  }

  Future<void> _runSequence() async {
    if (_doOpen) {
      setState(() => _timerStatus = "Apertura cover...");
      await widget.onCommand("OPEN_CLOSE");
      await _waitReady();
    }
    setState(() => _timerStatus = "Impostazione luminosità preset ${kPresets[_targetPreset]}...");
    await widget.onCommand("BRIGHTNESS:$_targetPreset");
    await _waitReady();
    setState(() => _timerStatus = "✓ Pannello pronto per i flat");
  }

  Future<void> _waitReady({int maxSecs = 120}) async {
    int i = 0;
    while (widget.busy.value && i++ < maxSecs) {
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  String _fmt(Duration d) {
    if (d.inSeconds <= 0) return "--:--:--";
    return "${d.inHours.toString().padLeft(2,'0')}:"
           "${(d.inMinutes % 60).toString().padLeft(2,'0')}:"
           "${(d.inSeconds % 60).toString().padLeft(2,'0')}";
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("⏱  Timer Automatico",
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text("Sincronizza il pannello con la fine della sessione ASIAir",
          style: TextStyle(color: Colors.white38, fontSize: 13)),
        const SizedBox(height: 24),
        if (!_timerActive) ...[
          _modeSelector(),
          const SizedBox(height: 20),
          if (_mode == "delay") _delayPicker() else _absPicker(),
          const SizedBox(height: 24),
          _sequenceConfig(),
          const SizedBox(height: 24),
          _startButton(),
        ] else ...[
          _timerDisplay(),
          const SizedBox(height: 20),
          _cancelButton(),
        ],
        if (_timerStatus.isNotEmpty && !_timerActive) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(12)),
            child: Text(_timerStatus,
              style: const TextStyle(color: Colors.white70, fontSize: 14))),
        ],
      ]),
    ),
  );

  Widget _modeSelector() => Container(
    decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      Expanded(child: _modeBtn("delay", "⏳ Ritardo")),
      Expanded(child: _modeBtn("absolute", "🕐 Ora esatta")),
    ]),
  );

  Widget _modeBtn(String mode, String label) => GestureDetector(
    onTap: () => setState(() => _mode = mode),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: _mode == mode ? const Color(0xFF7B68EE) : Colors.transparent,
        borderRadius: BorderRadius.circular(10)),
      child: Center(child: Text(label, style: TextStyle(
        color: _mode == mode ? Colors.white : Colors.white38,
        fontWeight: _mode == mode ? FontWeight.w600 : FontWeight.normal,
        fontSize: 14))),
    ),
  );

  Widget _delayPicker() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text("RITARDO", style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.2)),
    const SizedBox(height: 12),
    Row(children: [
      Expanded(child: _spinner("Ore",    _delayHours, 0, 23, (v) => setState(() => _delayHours = v))),
      const SizedBox(width: 12),
      Expanded(child: _spinner("Minuti", _delayMins,  0, 59, (v) => setState(() => _delayMins  = v))),
    ]),
    const SizedBox(height: 8),
    Center(child: Text("Parte tra $_delayHours ore e $_delayMins minuti",
      style: const TextStyle(color: Colors.white38, fontSize: 13))),
  ]);

  Widget _absPicker() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text("ORA DI ATTIVAZIONE", style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.2)),
    const SizedBox(height: 12),
    GestureDetector(
      onTap: () async {
        final t = await showTimePicker(context: context, initialTime: _absTime,
          builder: (ctx, child) => Theme(
            data: ThemeData.dark().copyWith(
              colorScheme: const ColorScheme.dark(primary: Color(0xFF7B68EE))),
            child: child!));
        if (t != null) setState(() => _absTime = t);
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF7B68EE).withOpacity(0.3))),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.access_time, color: Color(0xFF7B68EE), size: 28),
          const SizedBox(width: 12),
          Text(
            "${_absTime.hour.toString().padLeft(2,'0')}:${_absTime.minute.toString().padLeft(2,'0')}",
            style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
        ]),
      ),
    ),
    const SizedBox(height: 8),
    const Center(child: Text("Se passata, parte domani",
      style: TextStyle(color: Colors.white24, fontSize: 12))),
  ]);

  Widget _sequenceConfig() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text("SEQUENZA AL TRIGGER", style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.2)),
    const SizedBox(height: 12),
    _seqSwitch("Apri cover", _doOpen, (v) => setState(() => _doOpen = v)),
    const SizedBox(height: 16),
    const Text("Luminosità target:", style: TextStyle(color: Colors.white70, fontSize: 14)),
    const SizedBox(height: 10),
    SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: kPresets.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final isSel = i == _targetPreset;
          return GestureDetector(
            onTap: () => setState(() => _targetPreset = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 48, height: 48,
              decoration: BoxDecoration(
                color: isSel ? const Color(0xFFFFD700).withOpacity(0.15) : const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSel ? const Color(0xFFFFD700) : Colors.white12,
                  width: isSel ? 2 : 1)),
              child: Center(child: Text("${kPresets[i]}",
                style: TextStyle(
                  color: isSel ? const Color(0xFFFFD700) : Colors.white54,
                  fontSize: 12, fontWeight: isSel ? FontWeight.bold : FontWeight.normal))),
            ),
          );
        },
      ),
    ),
    const SizedBox(height: 16),
    _seqSwitch("Chiudi cover dopo sessione", _doClose, (v) => setState(() => _doClose = v)),
    const SizedBox(height: 8),
    Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(10)),
      child: const Text(
        "💡 La luce rimane accesa dopo il trigger. Quando i flat sono finiti, vai in tab Controllo → Spegni Luce.",
        style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5))),
  ]);

  Widget _seqSwitch(String label, bool val, ValueChanged<bool> cb) => Row(children: [
    Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14))),
    Switch(value: val, onChanged: cb, activeColor: const Color(0xFF7B68EE)),
  ]);

  Widget _startButton() => SizedBox(
    width: double.infinity, height: 56,
    child: ElevatedButton.icon(
      onPressed: _startTimer,
      icon: const Icon(Icons.play_arrow_rounded),
      label: Text(_mode == "delay"
          ? "Avvia tra ${_delayHours}h ${_delayMins}m"
          : "Avvia alle ${_absTime.hour.toString().padLeft(2,'0')}:${_absTime.minute.toString().padLeft(2,'0')}"),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF7B68EE), foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    ),
  );

  Widget _timerDisplay() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      color: const Color(0xFF1A1A2E),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFF7B68EE).withOpacity(0.3))),
    child: Column(children: [
      const Text("ATTIVAZIONE TRA", style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
      const SizedBox(height: 12),
      Text(_fmt(_remaining), style: const TextStyle(
        color: Colors.white, fontSize: 52, fontWeight: FontWeight.bold)),
      if (_scheduledAt != null) ...[
        const SizedBox(height: 8),
        Text("→ ${_scheduledAt!.hour.toString().padLeft(2,'0')}:${_scheduledAt!.minute.toString().padLeft(2,'0')}",
          style: const TextStyle(color: Colors.white38, fontSize: 14)),
      ],
      if (_timerStatus.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(_timerStatus, style: const TextStyle(color: Color(0xFFFFD700), fontSize: 14)),
      ],
    ]),
  );

  Widget _cancelButton() => SizedBox(
    width: double.infinity, height: 50,
    child: OutlinedButton.icon(
      onPressed: _cancelTimer,
      icon: const Icon(Icons.stop_circle_outlined),
      label: const Text("Annulla timer"),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFFF6B6B),
        side: const BorderSide(color: Color(0xFFFF6B6B), width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
  );

  Widget _spinner(String label, int val, int min, int max, ValueChanged<int> cb) =>
      Container(
        decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          IconButton(onPressed: val > min ? () => cb(val-1) : null,
            icon: const Icon(Icons.remove, size: 18), color: const Color(0xFF7B68EE)),
          Text("$val", style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          IconButton(onPressed: val < max ? () => cb(val+1) : null,
            icon: const Icon(Icons.add, size: 18), color: const Color(0xFF7B68EE)),
        ]),
      );
}

// ── Command Card ──────────────────────────────────────────────────────────────
class _CmdCard extends StatelessWidget {
  final IconData icon; final String label, sub; final Color color;
  final bool enabled; final VoidCallback onTap;
  const _CmdCard({required this.icon, required this.label, required this.sub,
      required this.color, required this.enabled, required this.onTap});
  @override
  Widget build(BuildContext context) => Opacity(
    opacity: enabled ? 1 : 0.35,
    child: GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.25))),
        child: Row(children: [
          Container(padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 24)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 15,
                fontWeight: FontWeight.w600)),
            Text(sub, style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ])),
          Icon(Icons.chevron_right, color: color.withOpacity(0.4)),
        ]),
      ),
    ),
  );
}
